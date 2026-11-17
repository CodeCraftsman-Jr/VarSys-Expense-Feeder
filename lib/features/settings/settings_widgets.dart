import 'package:flutter/material.dart';

import '../../core/theme/palette.dart';
import '../../ui/widgets.dart';

/// A titled group of settings rows in one rounded card, split by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            title.toUpperCase(),
            style: context.text.labelMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        AppCard(padding: EdgeInsets.zero, child: Column(children: children)),
      ],
    );
  }
}

/// One settings row: a tinted icon, a title, one line of status, and one control on the right.
///
/// It is laid out by hand and not with a ListTile on purpose: the app theme gives every button a
/// full-width minimum size, which a ListTile's trailing slot cannot hold (the row then fails to lay out).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
    this.tint,
    this.divider = true,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// Defaults to the muted text color; red for an error line.
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? tint;

  /// A hairline above the row. Leave it off for the first row of a group.
  final bool divider;
  final bool destructive;

  /// A compact button for a row: the theme's own buttons are full width.
  static ButtonStyle get compactButton =>
      FilledButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 16));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final tintColor = destructive ? Palette.red : (tint ?? colors.primary);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (divider)
          Divider(height: 1, thickness: 1, indent: 66, color: colors.outlineVariant.withValues(alpha: 0.5)),
        MergeSemantics(
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: tintColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 20, color: tintColor),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title,
                            style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: destructive ? Palette.red : null,
                            ),
                          ),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle!,
                                style: text.bodySmall?.copyWith(color: subtitleColor ?? colors.onSurfaceVariant),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[const SizedBox(width: 12), trailing!],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
