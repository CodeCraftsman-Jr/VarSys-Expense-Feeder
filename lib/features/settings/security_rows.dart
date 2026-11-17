import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/app_lock.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/db_encryption.dart';
import 'settings_widgets.dart';

/// App lock, hide in recents, and the database encryption status, as settings rows.
class SecurityRows extends ConsumerWidget {
  const SecurityRows({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider);
    final ctrl = ref.read(appLockProvider.notifier);

    Future<void> setLock(bool v) async {
      final error = await ctrl.setEnabled(v);
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          icon: PhosphorIconsRegular.fingerprint,
          title: 'App lock',
          subtitle: 'Fingerprint, face or screen lock when MoneyTrail opens or returns after 2 minutes',
          divider: false,
          onTap: lock.authenticating ? null : () => setLock(!lock.enabled),
          trailing: Switch(value: lock.enabled, onChanged: lock.authenticating ? null : setLock),
        ),
        SettingsRow(
          icon: PhosphorIconsRegular.eyeSlash,
          title: 'Hide in recent apps',
          subtitle: 'Blank in the app switcher and no screenshots',
          onTap: () => ctrl.setHideInRecents(!lock.hideInRecents),
          trailing: Switch(value: lock.hideInRecents, onChanged: ctrl.setHideInRecents),
        ),
        ValueListenableBuilder(
          valueListenable: DbEncryption.status,
          builder: (context, status, _) => SettingsRow(
            icon: status.encrypted ? PhosphorIconsRegular.lockSimple : PhosphorIconsRegular.warningCircle,
            tint: status.encrypted ? Palette.green : Palette.amber,
            title: status.encrypted ? 'Database encrypted' : 'Database not encrypted',
            subtitle: status.encrypted
                ? 'AES-256${status.cipherVersion == null ? '' : ' (SQLCipher ${status.cipherVersion!.split(' ').first})'}. '
                      "The key never leaves this phone's keystore."
                : status.detail,
          ),
        ),
      ],
    );
  }
}
