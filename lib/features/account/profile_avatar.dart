import 'package:flutter/material.dart';

import '../../account/varsys_auth.dart';
import '../../ui/widgets.dart';

/// The signed-in member's photo in a circle. The initial sits underneath, so it shows while the
/// photo loads, when the member has none, when the phone is offline, and if the link fails.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, required this.profile, this.size = 36});

  final AuthProfile? profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final name = p == null ? '' : ((p.name?.trim().isNotEmpty ?? false) ? p.name!.trim() : (p.email ?? ''));
    final initial = name.isEmpty ? null : name.characters.first.toUpperCase();
    final color = context.colors.primary;
    final fallback = initial == null
        ? Icon(Icons.person_outline, size: size * 0.55, color: color)
        : Text(initial, style: context.text.titleMedium?.copyWith(color: color, fontSize: size * 0.42));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      child: p?.image == null
          ? fallback
          : Stack(
              alignment: Alignment.center,
              fit: StackFit.expand,
              children: [
                Center(child: fallback),
                Image.network(
                  p!.image!,
                  fit: BoxFit.cover,
                  cacheWidth: (size * 3).round(),
                  // While loading, and on any failure, the initial underneath stays visible.
                  frameBuilder: (context, child, frame, sync) => frame == null && !sync ? const SizedBox.shrink() : child,
                  errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                ),
              ],
            ),
    );
  }
}
