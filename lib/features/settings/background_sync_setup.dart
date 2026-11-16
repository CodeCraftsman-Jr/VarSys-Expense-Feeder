import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = MethodChannel('moneytrail/device');
const _askedKey = 'bg.sync.askedAt';
const _autostartKey = 'bg.sync.autostartShown';

/// Android lets MoneyTrail sync in the background only after the user allows unrestricted
/// battery use (and, on Xiaomi, Autostart). The app asks for both itself, at start-up, until
/// they are granted: at most once every 3 days after a "Not now", so it never nags.
Future<void> askBackgroundSync(BuildContext context, SharedPreferences prefs) async {
  if (!Platform.isAndroid) return;
  try {
    final unrestricted = await _device.invokeMethod<bool>('batteryUnrestricted') ?? true;
    if (!unrestricted) {
      final last = prefs.getInt(_askedKey) ?? 0;
      final due = DateTime.now().millisecondsSinceEpoch - last > const Duration(days: 3).inMilliseconds;
      if (!due || !context.mounted) return;
      await prefs.setInt(_askedKey, DateTime.now().millisecondsSinceEpoch);
      if (!context.mounted) return;
      final go = await _confirm(
        context,
        title: 'Keep MoneyTrail syncing',
        body: 'To send new bank messages even when the app is closed, Android needs your '
            'permission to let MoneyTrail run without battery limits. It only wakes up when '
            'a bank message arrives or about every 30 minutes.',
        yes: 'Allow',
        no: 'Not now',
      );
      if (go != true) return;
      // Android 13+: the short "Syncing" notification needs this.
      await _device.invokeMethod<void>('requestNotifications');
      await _device.invokeMethod<void>('requestBatteryUnrestricted');
      return;
    }
    // Battery is allowed. Xiaomi phones also keep an Autostart list.
    if ((prefs.getBool(_autostartKey) ?? false) || !context.mounted) return;
    if (await _device.invokeMethod<bool>('autostartPage') != true) return;
    await prefs.setBool(_autostartKey, true);
    if (!context.mounted) return;
    final open = await _confirm(
      context,
      title: 'One more switch on this phone',
      body: 'Xiaomi, Redmi and POCO phones block background starts unless MoneyTrail is '
          'switched on in the Autostart list. Turn it on, then come back.',
      yes: 'Open Autostart',
      no: 'Later',
    );
    if (open == true) await _device.invokeMethod<bool>('openAutostart');
  } on PlatformException {
    // Not an Android build with these calls: nothing to ask.
  } on MissingPluginException {
    // Tests.
  }
}

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String yes,
  required String no,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
      ],
    ),
  );
}
