package com.varsys.moneytrail

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * After a reboot or an app update, puts the 30-minute background sync back on the schedule and
 * runs one catch-up now, so SMS that arrived while the phone was off are sent without opening
 * the app. The sync itself checks that SMS import is on and the permission is granted.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        SyncWorker.schedulePeriodic(context)
        SyncWorker.runSoon(context)
    }
}
