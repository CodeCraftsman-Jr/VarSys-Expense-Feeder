import 'package:flutter/services.dart';

import 'feed_api.dart';

const _channel = MethodChannel('moneytrail/device');

/// Phone name and app version from the native side (MainActivity `appInfo`),
/// for the feed device registry. Kept apart from feed_api.dart so the API
/// client stays plain Dart.
Future<AppInfo> readAppInfo() async {
  try {
    final m = await _channel.invokeMapMethod<String, Object?>('appInfo');
    final label = (m?['label'] as String?)?.trim();
    return AppInfo(
      label: label == null || label.isEmpty ? 'Android phone' : label,
      version: (m?['version'] as String?) ?? 'unknown',
    );
  } on Object {
    return const AppInfo(label: 'Phone', version: 'unknown');
  }
}
