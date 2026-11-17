import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../account/account_providers.dart';
import '../../account/feed_api.dart';
import '../../account/varsys_auth.dart';
import '../../core/theme/icons.dart';
import '../../feed/feed_sync.dart';
import '../../core/theme/palette.dart';
import '../../ui/widgets.dart';
import 'profile_avatar.dart';

/// The VarSys account that links this phone to a Joint Journey team. Shown in the profile sheet
/// opened from the Activity header.
class AccountCard extends ConsumerWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final profile = account.profile;
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProfileAvatar(profile: profile, size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile == null ? 'VarSys account' : _displayName(profile),
                      style: context.text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      profile == null
                          ? 'Not signed in'
                          : account.checking
                          ? 'Checking...'
                          : account.offline
                          ? 'Offline, showing last known team'
                          : profile.hasTeam
                          ? 'Joint Journey team, ${_roleLabel(profile.role)}'
                          : 'No team yet',
                      style: muted,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (account.notice != null) ...[
            const SizedBox(height: 10),
            Text(account.notice!, style: context.text.bodySmall?.copyWith(color: Palette.amber)),
          ],
          if (profile != null && account.device != null && account.device != DeviceStatus.noTeam) ...[
            const SizedBox(height: 10),
            _DeviceLine(status: account.device!, message: account.deviceMessage),
          ],
          if (profile != null && account.device == DeviceStatus.registered) ...[
            const SizedBox(height: 10),
            _FeedSection(isAlpha: profile.role == TeamRole.alpha),
          ],
          const SizedBox(height: 10),
          Text(
            profile == null
                ? 'Sign in to link this phone to your Joint Journey team. Transactions stay on this phone until the team feed is switched on.'
                : 'Bank transactions go to your Joint Journey team while the team feed is on.',
            style: muted,
          ),
          const SizedBox(height: 14),
          if (profile == null)
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
              onPressed: () => context.push('/account/sign-in'),
              child: const Text('Sign in'),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: account.checking ? null : ref.read(accountProvider.notifier).refresh,
                    icon: const Icon(PhosphorIconsBold.arrowsClockwise, size: 18),
                    label: const Text('Refresh'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _confirmSignOut(context, ref),
                    icon: const Icon(PhosphorIconsBold.signOut, size: 18),
                    label: const Text('Sign out'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _displayName(AuthProfile p) => (p.name?.trim().isNotEmpty ?? false) ? p.name!.trim() : (p.email ?? 'Signed in');

  static String _roleLabel(TeamRole r) => switch (r) {
    TeamRole.alpha => 'alpha',
    TeamRole.beta => 'beta',
    TeamRole.gamma => 'gamma',
  };

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to use MoneyTrail. Transactions on this phone are kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok == true) await ref.read(accountProvider.notifier).signOut();
  }
}

/// Whether this phone is registered for the team feed.
class _DeviceLine extends StatelessWidget {
  const _DeviceLine({required this.status, this.message});

  final DeviceStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final ok = status == DeviceStatus.registered;
    final warn = status == DeviceStatus.revoked || status == DeviceStatus.failed;
    final color = ok ? Palette.green : warn ? Palette.amber : context.colors.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(ok ? PhosphorIconsBold.checkCircle : PhosphorIconsBold.deviceMobile, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ok ? 'This phone is registered with your team.' : (message ?? 'Phone not registered yet.'),
            style: context.text.bodySmall?.copyWith(color: warn ? color : context.colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Team feed status for this phone: on or off, how many transactions were
/// sent and how many wait, Send now, and (alpha only) the team switch.
class _FeedSection extends ConsumerStatefulWidget {
  const _FeedSection({required this.isAlpha});

  final bool isAlpha;

  @override
  ConsumerState<_FeedSection> createState() => _FeedSectionState();
}

class _FeedSectionState extends ConsumerState<_FeedSection> {
  var _saving = false;

  @override
  void initState() {
    super.initState();
    // Settings and counts are only known after a run; start one if none yet.
    if (ref.read(feedSyncProvider).lastRun == null) {
      Future.microtask(() => ref.read(feedSyncProvider.notifier).run());
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() => _saving = true);
    final error = await ref.read(feedSyncProvider.notifier).setTeamFeed(on);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(feedSyncProvider);
    final muted = context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant);
    final from = feed.settings?.backfillStart;
    final status = feed.running
        ? 'Sending to Joint Journey...'
        : feed.message != null
        ? [feed.message!, if ((feed.pending ?? 0) > 0) '${feed.pending} waiting to send.'].join(' ')
        : feed.settings == null
        ? 'Checking the team feed...'
        : [
            'Team feed is on${from == null ? '' : ', from ${DateFormat('d MMM yyyy').format(from)}'}.',
            if (feed.pending != null) feed.pending == 0 ? 'Everything is sent.' : '${feed.pending} waiting to send.',
          ].join(' ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              feed.feedOn ? PhosphorIconsBold.cloudArrowUp : PhosphorIconsBold.cloudSlash,
              size: 16,
              color: feed.message != null && feed.feedOn ? Palette.amber : context.colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(status, style: muted)),
          ],
        ),
        if (widget.isAlpha && feed.settings != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Team feed'),
            subtitle: const Text('Members\' phones send bank transactions to Joint Journey'),
            value: feed.feedOn,
            onChanged: _saving ? null : _toggle,
          ),
        if (feed.feedOn)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: feed.running ? null : () => ref.read(feedSyncProvider.notifier).run(),
              icon: const Icon(PhosphorIconsBold.paperPlaneTilt, size: 16),
              label: const Text('Send now'),
            ),
          ),
      ],
    );
  }
}
