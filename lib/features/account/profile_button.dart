import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../account/account_providers.dart';
import '../../account/feed_api.dart';
import '../../core/theme/palette.dart';
import '../../ui/widgets.dart';
import 'account_card.dart';
import 'profile_avatar.dart';

/// The round profile button in the Activity header. It shows the member's photo (their initial when
/// they have none), with a small
/// dot when something needs a look (not signed in, a notice, or this phone is not registered).
/// Tapping it opens the profile: name, team, role, the team feed switch and Sign out.
class ProfileButton extends ConsumerWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    final profile = account.profile;
    final needsLook =
        profile == null ||
        account.notice != null ||
        (account.device != null &&
            account.device != DeviceStatus.registered &&
            account.device != DeviceStatus.noTeam);
    return Semantics(
      button: true,
      label: needsLook ? 'Profile, needs attention' : 'Profile',
      child: InkResponse(
        onTap: () => showProfileSheet(context),
        radius: 28,
        // The label above says it all; the initial inside would be read out as well.
        child: ExcludeSemantics(
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ProfileAvatar(profile: profile, size: 36),
                if (needsLook)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Palette.amber,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showProfileSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  useRootNavigator: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    maxChildSize: 0.95,
    builder: (_, scroll) => _ProfileSheet(scroll: scroll),
  ),
);

class _ProfileSheet extends ConsumerWidget {
  const _ProfileSheet({required this.scroll});

  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Signing out sends the app to the sign-in screen: close the sheet with it.
    ref.listen(accountProvider.select((s) => s.signedIn), (was, now) {
      if (was == true && !now && context.mounted) Navigator.of(context).pop();
    });
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text('Profile', style: context.text.headlineSmall),
        ),
        const AccountCard(),
      ],
    );
  }
}
