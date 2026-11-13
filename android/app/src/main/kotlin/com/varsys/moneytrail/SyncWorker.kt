package com.varsys.moneytrail

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Telephony
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Imports new bank SMS and sends them to Joint Journey without the app being opened (feed plan
 * revision 5): every 30 minutes, and about a minute after a bank SMS arrives. It starts a headless
 * Flutter engine that runs `backgroundSync` in main.dart, the same Dart pipeline the app runs on
 * resume (parse, dedup, store, upload, withdraw), and waits for it to report back.
 *
 * Skipped while the app is on screen: its own resume sync is already running.
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (MainActivity.visible) return Result.success()
        val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(PREF_SMS, false) || !hasSmsPermission(applicationContext)) return Result.success()

        val done = CompletableDeferred<Boolean>()
        val engine = withContext(Dispatchers.Main) {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            FlutterEngine(applicationContext).also { e ->
                BackgroundChannels.register(e.dartExecutor.binaryMessenger, applicationContext)
                MethodChannel(e.dartExecutor.binaryMessenger, "moneytrail/background").setMethodCallHandler { call, result ->
                    if (call.method == "done") {
                        done.complete(call.arguments == true)
                        result.success(null)
                    } else {
                        result.notImplemented()
                    }
                }
                e.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundSync"),
                )
            }
        }
        val ok = withTimeoutOrNull(TIMEOUT_MS) { done.await() }
        withContext(Dispatchers.Main) { engine.destroy() }
        Log.i(TAG, "background sync finished: ${ok ?: "timed out"}")
        // A failed run is not retried in a loop: the next periodic run or SMS tries again.
        return Result.success()
    }

    companion object {
        private const val TAG = "moneytrail-sync"
        private const val PERIODIC = "moneytrail-periodic-sync"
        private const val ON_SMS = "moneytrail-sms-sync"
        private const val TIMEOUT_MS = 8 * 60_000L
        private const val PREFS = "FlutterSharedPreferences"
        private const val PREF_SMS = "flutter.sms.enabled"

        private val network = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        /** Keeps one 30-minute job scheduled; called on every app start. */
        fun schedulePeriodic(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(30, TimeUnit.MINUTES)
                .setConstraints(network)
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        /** One run shortly after a bank SMS; more SMS meanwhile join the same run. */
        fun runSoon(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setInitialDelay(1, TimeUnit.MINUTES)
                .setConstraints(network)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(ON_SMS, ExistingWorkPolicy.KEEP, request)
        }

        fun hasSmsPermission(context: Context) =
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
    }
}

/**
 * The native calls the Dart sync pipeline needs, without an Activity: inbox reading and the
 * permission check on `moneytrail/sms`, and app info on `moneytrail/device`. Calls that need a
 * screen (permission prompts) answer false or do nothing.
 */
object BackgroundChannels {
    private val io = Executors.newSingleThreadExecutor()

    fun register(messenger: BinaryMessenger, context: Context) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        MethodChannel(messenger, "moneytrail/sms").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(SyncWorker.hasSmsPermission(context))
                "hasReceivePermission" -> result.success(
                    ContextCompat.checkSelfPermission(context, Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED,
                )
                "requestPermission" -> result.success(false)
                "readInbox" -> {
                    val since = call.argument<Number>("sinceMillis")?.toLong() ?: 0L
                    val limit = call.argument<Int>("limit") ?: 5000
                    io.execute {
                        try {
                            val rows = readInbox(context, since, limit)
                            main.post { result.success(rows) }
                        } catch (e: SecurityException) {
                            main.post { result.error("PERMISSION", e.message, null) }
                        } catch (e: Exception) {
                            main.post { result.error("READ_FAILED", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "moneytrail/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "appInfo" -> result.success(appInfo(context))
                "requestNotifications" -> result.success(null)
                "notificationsAllowed" -> result.success(false)
                else -> result.notImplemented()
            }
        }
    }

    fun appInfo(context: Context): Map<String, Any?> {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        return mapOf(
            "label" to listOf(Build.MANUFACTURER, Build.MODEL).filter { it.isNotBlank() }.joinToString(" "),
            "version" to "${info.versionName}+$code",
        )
    }

    /** Inbox messages newer than [since], oldest first. */
    fun readInbox(context: Context, since: Long, limit: Int): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI,
            arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE),
            "${Telephony.Sms.DATE} > ?",
            arrayOf(since.toString()),
            "${Telephony.Sms.DATE} ASC",
        )?.use { c ->
            val id = c.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addr = c.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val body = c.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val date = c.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (c.moveToNext() && out.size < limit) {
                out.add(
                    mapOf(
                        "id" to c.getLong(id).toString(),
                        "address" to (c.getString(addr) ?: ""),
                        "body" to (c.getString(body) ?: ""),
                        "date" to c.getLong(date),
                    ),
                )
            }
        }
        return out
    }
}
