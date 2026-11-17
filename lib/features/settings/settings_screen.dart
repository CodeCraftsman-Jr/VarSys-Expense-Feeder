import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_providers.dart';
import '../../core/theme/icons.dart';
import '../../ingestion/email/email_sync.dart';
import '../../providers.dart';
import '../../ui/widgets.dart';
import 'capture_rows.dart';
import 'security_rows.dart';
import 'settings_widgets.dart';
import 'status_banner.dart';

final _versionProvider = FutureProvider<String>((ref) async => (await ref.read(appInfoProvider)()).version);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final version = ref.watch(_versionProvider).value;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 16),
              child: Text('Settings', style: context.text.headlineSmall),
            ),
            const StatusBanner(),
            const SizedBox(height: 24),
            const CaptureGroup(),
            const SizedBox(height: 24),
            const RunningGroup(),
            const SizedBox(height: 24),
            SettingsGroup(
              title: 'Look',
              children: [
                SettingsRow(
                  icon: PhosphorIconsRegular.moon,
                  title: 'Theme',
                  divider: false,
                  trailing: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: ThemeMode.system, icon: Icon(PhosphorIconsRegular.deviceMobile), tooltip: 'System'),
                      ButtonSegment(value: ThemeMode.dark, icon: Icon(PhosphorIconsRegular.moon), tooltip: 'Dark'),
                      ButtonSegment(value: ThemeMode.light, icon: Icon(PhosphorIconsRegular.sun), tooltip: 'Light'),
                    ],
                    selected: {themeMode},
                    onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              title: 'Privacy and security',
              children: [
                const SecurityRows(),
                SettingsRow(
                  icon: PhosphorIconsRegular.shieldCheck,
                  title: 'What your team receives',
                  subtitle: 'Parsed transactions and the original message text',
                  onTap: () => _showTeamData(context),
                  trailing: const Icon(PhosphorIconsBold.caretRight, size: 16),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              title: 'Data',
              children: [
                SettingsRow(
                  icon: PhosphorIconsRegular.trash,
                  title: 'Reset imported data',
                  subtitle: 'Clear transactions, messages and saved payloads. Upload status is kept.',
                  destructive: true,
                  divider: false,
                  onTap: () => _confirmReset(context, ref),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SettingsGroup(
              title: 'About',
              children: [
                SettingsRow(
                  icon: PhosphorIconsRegular.info,
                  title: 'VarSys MoneyTrail',
                  subtitle: '${version == null ? '' : 'Version $version. '}Free software, GPL-3.0',
                  divider: false,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'VarSys MoneyTrail',
                    applicationVersion: version,
                    applicationLegalese: _legalese,
                  ),
                  trailing: const Icon(PhosphorIconsBold.caretRight, size: 16),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showTeamData(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: const Text('What your team receives'),
    content: const Text(
      'While your team feed is on, each bank transaction MoneyTrail reads is sent to your Joint Journey team '
      'with its parsed fields and the original SMS or email text. Your team sorts them on the web.\n\n'
      'Recent request details are kept in this phone’s encrypted database.',
    ),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
  ),
);

Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Reset imported data?'),
      content: const Text(
        'All transactions, parsed messages and saved request payloads will be deleted. '
        'You can re-import SMS afterwards.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reset')),
      ],
    ),
  );
  if (ok == true) {
    await ref.read(databaseProvider).resetImported();
    await ref.read(prefsProvider).remove(PrefKeys.smsLastSync);
    await ref.read(prefsProvider).remove(EmailPrefKeys.lastSync);
  }
}

/// GPL-3.0 section 5 asks modified versions to say they were changed and to
/// keep the original notices; this text is shown on the licenses page.
const _legalese =
    'VarSys MoneyTrail is a modified version of Pckt '
    '(https://github.com/pritam-ravani/pckt), copyright its original author.\n\n'
    'This program is free software: you can redistribute it and/or modify it under the terms '
    'of the GNU General Public License version 3 as published by the Free Software Foundation. '
    'It comes with no warranty. Source code: https://github.com/CodeCraftsman-Jr/VarSys-Expense-Feeder';
