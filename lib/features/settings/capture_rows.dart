import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../ingestion/email/email_source.dart';
import '../../ingestion/email/email_sync.dart';
import '../../providers.dart';
import '../../ui/widgets.dart';
import 'background_sync_tile.dart';
import 'settings_widgets.dart';

/// "1,040 parsed · 9 merged · 1,617 ignored", plus unreadable ones when there are any.
String statsSummary(Map<ParseStatus, int> stats) {
  if (stats.isEmpty) return 'Nothing read yet';
  final parts = [
    '${stats[ParseStatus.parsed] ?? 0} parsed',
    '${stats[ParseStatus.merged] ?? 0} merged',
    '${stats[ParseStatus.ignored] ?? 0} ignored',
    if ((stats[ParseStatus.pendingLlm] ?? 0) > 0) '${stats[ParseStatus.pendingLlm]} unreadable',
  ];
  return parts.join(' · ');
}

/// Where bank messages come from: SMS, email, instant alerts, and the message logs.
class CaptureGroup extends ConsumerWidget {
  const CaptureGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sms = ref.watch(smsSyncProvider);
    final smsStats = ref.watch(smsStatsProvider).value ?? const <ParseStatus, int>{};
    final email = ref.watch(emailSyncProvider);
    final emailStats = ref.watch(emailStatsProvider).value ?? const <ParseStatus, int>{};
    final alerts = ref.watch(smsAlertsProvider);
    final supported = ref.read(smsSourceProvider).isSupported;
    final account = email.account;

    final smsLine = !supported
        ? 'Not available on iOS'
        : sms.error != null
        ? sms.error!
        : !sms.enabled
        ? 'Off. Bank SMS are not captured.'
        : sms.running
        ? 'Syncing…'
        : sms.lastSync == null
        ? 'On'
        : 'Synced ${relativeTime(sms.lastSync!)}';

    final emailLine = email.error != null
        ? email.error!
        : !email.enabled
        ? (account == null ? 'Bank alerts and receipts from your inbox' : 'Paused · ${account.address}')
        : email.running
        ? 'Syncing ${account?.address ?? ''}…'
        : email.lastSync == null
        ? account?.address ?? 'On'
        : '${account?.address ?? ''} · synced ${relativeTime(email.lastSync!)}';

    return SettingsGroup(
      title: 'Capture',
      children: [
        SettingsRow(
          icon: PhosphorIconsFill.chatText,
          tint: Palette.brand,
          title: 'SMS',
          subtitle: smsLine,
          subtitleColor: sms.error != null ? Palette.red : null,
          divider: false,
          // Only the switch turns SMS off: a tap on the row must never disconnect it by accident.
          trailing: !supported
              ? null
              : sms.enabled
              ? Switch(value: true, onChanged: (_) => ref.read(smsSyncProvider.notifier).disconnect())
              : FilledButton.tonal(
                  style: SettingsRow.compactButton,
                  onPressed: () => _pickRangeAndConnect(context, ref),
                  child: const Text('Connect'),
                ),
        ),
        SettingsRow(
          icon: PhosphorIconsFill.envelopeSimple,
          tint: Palette.amber,
          title: account == null || !email.enabled ? 'Email' : 'Email · ${_providerName(account.provider)}',
          subtitle: emailLine,
          subtitleColor: email.error != null ? Palette.red : null,
          onTap: email.enabled ? null : () => context.push('/email/connect'),
          trailing: email.enabled
              ? Switch(value: true, onChanged: (_) => _confirmDisconnectEmail(context, ref))
              : FilledButton.tonal(
                  style: SettingsRow.compactButton,
                  onPressed: () => context.push('/email/connect'),
                  child: Text(account == null ? 'Connect' : 'Reconnect'),
                ),
        ),
        if (supported && sms.enabled)
          SettingsRow(
            icon: PhosphorIconsRegular.bellRinging,
            title: 'Instant alerts',
            subtitle: 'Notify me when a bank SMS shows money moving',
            onTap: () => ref.read(smsAlertsProvider.notifier).set(!alerts),
            trailing: Switch(value: alerts, onChanged: (v) => ref.read(smsAlertsProvider.notifier).set(v)),
          ),
        if (supported && sms.enabled)
          SettingsRow(
            icon: PhosphorIconsRegular.listMagnifyingGlass,
            title: 'SMS message log',
            subtitle: statsSummary(smsStats),
            onTap: () => context.push('/messages'),
            trailing: const Icon(PhosphorIconsBold.caretRight, size: 16),
          ),
        if (email.enabled)
          SettingsRow(
            icon: PhosphorIconsRegular.listMagnifyingGlass,
            title: 'Email message log',
            subtitle: statsSummary(emailStats),
            onTap: () => context.push('/messages?source=email'),
            trailing: const Icon(PhosphorIconsBold.caretRight, size: 16),
          ),
      ],
    );
  }

  static String _providerName(EmailProvider p) => p == EmailProvider.gmailOAuth ? 'Gmail' : p.label;
}

/// What keeps capture flowing when the app is closed, and a button to send everything now.
class RunningGroup extends ConsumerWidget {
  const RunningGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sms = ref.watch(smsSyncProvider);
    final email = ref.watch(emailSyncProvider);
    final supported = ref.read(smsSourceProvider).isSupported;
    final busy = sms.running || email.running;
    final anySource = sms.enabled || email.enabled;

    return SettingsGroup(
      title: 'Keep it running',
      children: [
        if (supported && sms.enabled) const BackgroundSyncTile(divider: false),
        SettingsRow(
          icon: PhosphorIconsRegular.arrowsClockwise,
          title: 'Sync now',
          subtitle: !anySource
              ? 'Turn on SMS or connect email first'
              : busy
              ? 'Reading new messages…'
              : 'Read new messages and send them to your team',
          divider: supported && sms.enabled,
          onTap: !anySource || busy
              ? null
              : () {
                  if (sms.enabled) ref.read(smsSyncProvider.notifier).sync();
                  if (email.enabled) ref.read(emailSyncProvider.notifier).sync();
                },
          trailing: busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : null,
        ),
      ],
    );
  }
}

Future<void> _pickRangeAndConnect(BuildContext context, WidgetRef ref) async {
  final months = await showModalBottomSheet<int>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Import history from', style: c.text.titleMedium),
          ),
          for (final m in const [1, 3, 6, 12])
            ListTile(
              leading: const Icon(PhosphorIconsRegular.clockCounterClockwise),
              title: Text(m == 1 ? 'Last month' : 'Last $m months'),
              onTap: () => Navigator.pop(c, m),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (months != null) await ref.read(smsSyncProvider.notifier).connect(months: months);
}

Future<void> _confirmDisconnectEmail(BuildContext context, WidgetRef ref) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Disconnect email?'),
      content: const Text(
        'MoneyTrail stops reading this mailbox and forgets the password. '
        'Transactions already imported stay.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Disconnect')),
      ],
    ),
  );
  if (ok == true) await ref.read(emailSyncProvider.notifier).disconnect();
}
