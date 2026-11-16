import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/icons.dart';

/// Asks Android to let MoneyTrail sync in the background without battery limits, so bank
/// SMS reach Joint Journey within minutes instead of being delayed by battery savers.
class BackgroundSyncTile extends StatefulWidget {
  const BackgroundSyncTile({super.key});

  @override
  State<BackgroundSyncTile> createState() => _BackgroundSyncTileState();
}

class _BackgroundSyncTileState extends State<BackgroundSyncTile> with WidgetsBindingObserver {
  static const _device = MethodChannel('moneytrail/device');
  bool? _unrestricted;
  bool _autostart = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final ok = await _device.invokeMethod<bool>('batteryUnrestricted');
      final page = await _device.invokeMethod<bool>('autostartPage');
      if (mounted) {
        setState(() {
          _unrestricted = ok ?? false;
          _autostart = page ?? false;
        });
      }
    } on PlatformException {
      if (mounted) setState(() => _unrestricted = null);
    } on MissingPluginException {
      if (mounted) setState(() => _unrestricted = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _unrestricted;
    if (ok == null) return const SizedBox.shrink();
    final tile = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(PhosphorIconsRegular.clockCounterClockwise),
        title: const Text('Background sync'),
        subtitle: Text(
          ok
              ? 'Allowed. Bank SMS are sent even when the app is closed.'
              : 'Battery limits may delay sending. Allow unrestricted use so nothing waits.',
        ),
        trailing: ok
            ? null
            : FilledButton.tonal(
                onPressed: () async {
                  await _device.invokeMethod<void>('requestNotifications');
                  await _device.invokeMethod<void>('requestBatteryUnrestricted');
                },
                child: const Text('Allow'),
              ),
      ),
    );
    return Column(
      children: [
        tile,
        if (_autostart)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(PhosphorIconsRegular.lightning),
            title: const Text('Autostart'),
            subtitle: const Text('Xiaomi phones also need MoneyTrail switched on in the Autostart list.'),
            trailing: FilledButton.tonal(
              onPressed: () => _device.invokeMethod<bool>('openAutostart'),
              child: const Text('Open'),
            ),
          ),
      ],
    );
  }
}
