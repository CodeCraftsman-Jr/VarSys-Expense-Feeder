import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_providers.dart';
import '../../account/feed_api.dart';
import '../../core/format.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../feed/feed_sync.dart';
import '../../ingestion/email/email_sync.dart';
import '../../providers.dart';
import '../../ui/widgets.dart';

/// One look at the top of Settings: is everything being captured and sent, or does something need
/// attention? It reads the same state as the rows below, so it never disagrees with them.
class StatusBanner extends ConsumerWidget {
  const StatusBanner({super.key});

  /// What is wrong, most important first. Empty means all is well.
  static List<String> problems({
    required bool smsSupported,
    required bool smsEnabled,
    required String? smsError,
    required bool emailEnabled,
    required AccountState account,
    required FeedSyncState feed,
  }) {
    return [
      if (smsSupported && !smsEnabled && !emailEnabled) 'Nothing is being captured. Turn on SMS or connect email.',
      if (smsError != null) 'SMS: $smsError',
      if (account.device != null && account.device != DeviceStatus.registered && account.device != DeviceStatus.noTeam)
        account.deviceMessage ?? 'This phone is not registered with your team.',
      if (feed.settings != null && !feed.feedOn) 'Your team feed is off, so nothing is sent.',
      if (feed.message != null && feed.settings != null && feed.feedOn) feed.message!,
      if ((feed.pending ?? 0) > 0 && feed.feedOn) '${feed.pending} waiting to send.',
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sms = ref.watch(smsSyncProvider);
    final email = ref.watch(emailSyncProvider);
    final feed = ref.watch(feedSyncProvider);
    final account = ref.watch(accountProvider);
    final supported = ref.read(smsSourceProvider).isSupported;

    final problems = StatusBanner.problems(
      smsSupported: supported,
      smsEnabled: sms.enabled,
      smsError: sms.error,
      emailEnabled: email.enabled,
      account: account,
      feed: feed,
    );
    final working = sms.running || email.running || feed.running;
    final last = [sms.lastSync, email.lastSync, feed.lastRun].whereType<DateTime>().fold<DateTime?>(
      null,
      (a, b) => a == null || b.isAfter(a) ? b : a,
    );

    final Color color;
    final IconData icon;
    final String title;
    final List<String> lines;
    if (problems.isNotEmpty) {
      color = Palette.amber;
      icon = PhosphorIconsFill.warningCircle;
      title = 'Needs attention';
      lines = problems.take(3).toList();
    } else if (working) {
      color = context.colors.primary;
      icon = PhosphorIconsBold.arrowsClockwise;
      title = 'Syncing';
      lines = const ['Reading new messages and sending them to your team.'];
    } else {
      color = Palette.green;
      icon = PhosphorIconsFill.checkCircle;
      title = 'All set';
      lines = [last == null ? 'Bank messages are captured and sent to your team.' : 'Last synced ${relativeTime(last)}. Everything is sent.'];
    }

    return Semantics(
      container: true,
      label: '$title. ${lines.join(' ')}',
      child: ExcludeSemantics(
        child: AppCard(
          color: color.withValues(alpha: 0.12),
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    for (final line in lines)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(line, style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
