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
    final sent = summary.status == 'accepted' || summary.status == 'already_received';
    // Once the team has decided, show that instead of the bare "Sent".
    final outcome = sent ? summary.reviewState : 'pending';
    final color = switch (summary.status) {
      'accepted' || 'already_received' => outcome == 'pending' || outcome == 'confirmed' ? Palette.amber : Palette.green,
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
    final category = [summary.decidedCategory, summary.decidedSubCategory].whereType<String>().join(' · ');
    final label = switch (summary.status) {
      'accepted' || 'already_received' => switch (outcome) {
        'added' || 'linked' => category.isEmpty ? 'In your ledger' : 'In ledger · $category',
        'transfer' => 'Transfer',
        'ignored' => 'Not a transaction',
        _ => 'Sent · waiting for your team',
      },
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
