import 'package:flutter/material.dart';

import '../../core/theme/icons.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';

class FeedUploadStatusIndicator extends StatelessWidget {
  const FeedUploadStatusIndicator({super.key, required this.summary, this.compact = false});

  final FeedUploadSummary summary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = switch (summary.status) {
      'accepted' || 'already_received' => Palette.green,
      'rejected' => Palette.red,
      'client_outdated' => Palette.amber,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final icon = switch (summary.status) {
      'accepted' || 'already_received' => PhosphorIconsFill.checkCircle,
      'rejected' || 'client_outdated' => PhosphorIconsFill.warningCircle,
      'withdrawn' => PhosphorIconsBold.cloudSlash,
      _ => PhosphorIconsBold.cloudArrowUp,
    };
    final label = switch (summary.status) {
      'accepted' || 'already_received' => 'Sent',
      'rejected' => 'Rejected',
      'client_outdated' => 'Update needed',
      'withdrawn' => 'Withdrawn',
      _ => 'Status: ${summary.status}',
    };

    return Semantics(
      label: 'Joint Journey feed status: $label',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 14 : 18, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (compact ? Theme.of(context).textTheme.labelSmall : Theme.of(context).textTheme.labelMedium)
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
