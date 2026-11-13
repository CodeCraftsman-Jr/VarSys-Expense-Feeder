import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/account_providers.dart';
import '../feed/feed_sync.dart';
import '../providers.dart';

/// Reports the outcome to SyncWorker.kt, which waits for it and then shuts
/// the headless engine down.
const _done = MethodChannel('moneytrail/background');

/// Runs in the headless engine SyncWorker.kt starts while the app is closed
/// (feed plan revision 5): the same SMS import and Joint Journey upload the
/// app runs when it opens. Always answers `done`, so the worker never waits
/// for its full timeout.
Future<void> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  var ok = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    try {
      ok = await backgroundSyncOnce(container);
    } finally {
      container.dispose();
    }
  } catch (e, st) {
    debugPrint('[moneytrail-sync] background sync failed: $e\n$st');
  }
  try {
    await _done.invokeMethod<void>('done', ok);
  } on MissingPluginException {
    // Not started by SyncWorker (tests).
  }
}

/// One pass: import new SMS (which also runs the parser-change clean-ups),
/// then send to Joint Journey and take back rows the phone dropped. Signed
/// out or SMS off: nothing to do. Returns whether the pass completed.
@visibleForTesting
Future<bool> backgroundSyncOnce(ProviderContainer c) async {
  if (!c.read(accountProvider).signedIn) return true;
  if (!c.read(smsSyncProvider).enabled) return true;
  // Confirms the session and registers this phone again, which the upload
  // needs; a fresh engine has only the cached profile.
  await c.read(accountProvider.notifier).refresh();
  if (!c.read(accountProvider).signedIn) return true;
  await c.read(smsSyncProvider.notifier).sync();
  // The SMS sync starts an upload without waiting; this joins it (or starts
  // one when there was nothing new), so the engine stays up until it ends.
  await c.read(feedSyncProvider.notifier).run();
  return c.read(smsSyncProvider).error == null;
}
