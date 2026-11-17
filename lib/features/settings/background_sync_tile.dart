import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import 'settings_widgets.dart';

/// Asks Android to let MoneyTrail sync in the background without battery limits, so bank
/// SMS reach Joint Journey within minutes instead of being delayed by battery savers. On Xiaomi,
/// Redmi and POCO phones it also offers the Autostart page.
///
/// Draws settings rows (nothing at all until the phone has answered), so it can sit in any group.
class BackgroundSyncTile extends StatefulWidget {
  const BackgroundSyncTile({super.key, this.divider = true});

  /// A hairline above the first row; leave it off when this is the first row of a group.
  final bool divider;

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          icon: PhosphorIconsRegular.clockCounterClockwise,
          tint: ok ? Palette.green : Palette.amber,
          title: 'Background sync',
          subtitle: ok
              ? 'Allowed. Bank SMS are sent even when the app is closed.'
              : 'Battery limits may delay sending. Allow unrestricted use so nothing waits.',
          divider: widget.divider,
          trailing: ok
              ? const Icon(PhosphorIconsFill.checkCircle, color: Palette.green)
              : FilledButton.tonal(
                  style: SettingsRow.compactButton,
                  onPressed: () async {
                    await _device.invokeMethod<void>('requestNotifications');
                    await _device.invokeMethod<void>('requestBatteryUnrestricted');
                  },
                  child: const Text('Allow'),
                ),
        ),
        if (_autostart)
          SettingsRow(
            icon: PhosphorIconsRegular.lightning,
            title: 'Autostart',
            subtitle: 'Xiaomi phones also need MoneyTrail switched on in the Autostart list.',
            trailing: FilledButton.tonal(
              style: SettingsRow.compactButton,
              onPressed: () => _device.invokeMethod<bool>('openAutostart'),
              child: const Text('Open'),
            ),
          ),
      ],
    );
  }
}
