import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../account/account_providers.dart';
import '../../account/feed_api.dart';
import '../../account/varsys_auth.dart';
import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../ui/widgets.dart';

/// Settings entry for the VarSys account that links this phone to a
/// Joint Journey team.
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
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(PhosphorIconsFill.userCircle, color: context.colors.primary),
              ),
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
          const SizedBox(height: 10),
          Text(
            profile == null
                ? 'Sign in to link this phone to your Joint Journey team. Transactions stay on this phone until the team feed is switched on.'
                : 'Transactions stay on this phone until the team feed is switched on.',
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
    TeamRole.alpha => 'alpha (decides links)',
    TeamRole.beta => 'beta',
    TeamRole.gamma => 'gamma',
  };

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('Transactions on this phone are kept. You can sign in again at any time.'),
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
    final color = ok ? Palette.mint : warn ? Palette.amber : context.colors.onSurfaceVariant;
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
