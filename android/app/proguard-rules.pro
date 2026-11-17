# R8 rules for the release build (minify + resource shrinking).
# Flutter's own rules are added by the Flutter Gradle plugin; plugins ship
# consumer rules where they need them. These cover the gaps.

# Flutter references Play Core (deferred components) that this app doesn't use.
-dontwarn com.google.android.play.core.**

# background_downloader: WorkManager instantiates its workers by class name
# and task data is (de)serialised with kotlinx.serialization.
-keep class com.bbflight.background_downloader.** { *; }

# local_auth: BiometricPrompt callbacks.
-keep class androidx.biometric.** { *; }

# flutter_secure_storage: Tink / keystore-backed ciphers looked up reflectively.
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**

# Our MethodChannel handlers (SMS, device profile, FLAG_SECURE).
-keep class com.varsys.moneytrail.** { *; }

# Plugins that reach Java through Dart's `jni` package (shared_preferences_android and
# others): Dart looks their methods up by name, so R8 must not strip or rename them.
# Without this the release build died at startup with NoSuchMethodError on
# SharedPreferencesApiRegistrar.getAll and never left the splash screen.
-keep class io.flutter.plugins.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
# Their suspend functions take a kotlin.coroutines.Continuation and return Kotlin result types
# (CoroutineSingletons, Result$Failure, ...). Dart resolves every one of them by name while it
# calls in, so the Kotlin runtime keeps its names; keeping single classes only moved the failure
# to the next class (R8 renamed Continuation to "xd" and dropped CoroutineSingletons).
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
-dontwarn kotlin.**
-dontwarn kotlinx.coroutines.**

# SQLCipher, SQLite and LiteRT-LM are native libraries loaded through Dart FFI;
# enough_mail and drift are pure Dart.
