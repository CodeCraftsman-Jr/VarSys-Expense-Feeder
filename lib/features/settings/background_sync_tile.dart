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
    return Column(
      children: [
        _Row(
          icon: PhosphorIconsRegular.clockCounterClockwise,
          title: 'Background sync',
          subtitle: ok
              ? 'Allowed. Bank SMS are sent even when the app is closed.'
              : 'Battery limits may delay sending. Allow unrestricted use so nothing waits.',
          action: ok
              ? null
              : FilledButton.tonal(
                  style: _compact,
                  onPressed: () async {
                    await _device.invokeMethod<void>('requestNotifications');
                    await _device.invokeMethod<void>('requestBatteryUnrestricted');
                  },
                  child: const Text('Allow'),
                ),
        ),
        if (_autostart)
          _Row(
            icon: PhosphorIconsRegular.lightning,
            title: 'Autostart',
            subtitle: 'Xiaomi phones also need MoneyTrail switched on in the Autostart list.',
            action: FilledButton.tonal(
              style: _compact,
              onPressed: () => _device.invokeMethod<bool>('openAutostart'),
              child: const Text('Open'),
            ),
          ),
      ],
    );
  }
}

/// The app theme gives every button a full-width minimum size, which a ListTile's trailing slot
/// cannot hold (the whole card then fails to lay out). These rows are laid out by hand with a
/// compact button instead.
final _compact = FilledButton.styleFrom(minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 16));

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.subtitle, this.action});

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: muted),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall?.copyWith(color: muted)),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 12), action!],
        ],
      ),
    );
  }
}
