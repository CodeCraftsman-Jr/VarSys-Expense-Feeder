import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../account/account_providers.dart';
import '../../core/theme/icons.dart';

import '../../core/format.dart';
import '../../core/theme/palette.dart';
import '../../data/db/database.dart';
import '../../providers.dart';
import '../../ui/widgets.dart';
import 'feed_upload_status.dart';

/// "HDFC Bank ••1234" style label.
String accountLabel(Account a) => a.last4 == null || a.last4!.isEmpty ? a.name : '${a.name} ••${a.last4}';

Future<void> showTransactionSheet(BuildContext context, int id) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  useRootNavigator: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    maxChildSize: 0.95,
    builder: (_, scroll) => TransactionSheet(id: id, scroll: scroll),
  ),
);

class TransactionSheet extends ConsumerWidget {
  const TransactionSheet({super.key, required this.id, required this.scroll});

  final int id;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(txnProvider(id)).value;
    if (view == null) return const SizedBox(height: 200);
    final t = view.txn;
    final credit = t.direction == TxnDirection.credit;
    final sources = ref.watch(txnSourcesProvider(id)).value ?? const [];

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Center(
          child: CategoryBadge(category: view.category, isTransfer: t.isTransfer, size: 64),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '${credit ? '+' : '−'}${money(t.amountMinor, currency: t.currency, forceDecimals: true)}',
            style: context.text.displaySmall?.copyWith(
              color: credit && !t.isTransfer ? Palette.income : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (t.convertedMinor != null && t.convertedCurrency != null)
          Center(
            child: Text(
              '≈ ${money(t.convertedMinor!, currency: t.convertedCurrency, forceDecimals: true)}',
              style: context.text.titleSmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 4),
        Center(
          child: Text(txnTitle(t), style: context.text.titleMedium, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            dateTimeLabel(t.occurredAt),
            style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            InfoPill(icon: modeIcon(t.mode), label: modeLabel(t.mode)),
            if (view.account != null)
              InfoPill(icon: PhosphorIconsBold.bank, label: accountLabel(view.account!))
            else if (t.accountHint != null)
              InfoPill(icon: PhosphorIconsBold.bank, label: '••${t.accountHint}'),
            if (t.reference != null) InfoPill(icon: PhosphorIconsBold.hash, label: t.reference!),
            if (t.counterparty != null && t.counterparty != t.merchant)
              InfoPill(icon: PhosphorIconsBold.at, label: t.counterparty!),
          ],
        ),
        if (t.note != null && t.note!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.colors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(PhosphorIconsRegular.notePencil, size: 18, color: context.colors.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(child: Text(t.note!, style: context.text.bodyMedium)),
              ],
            ),
          ),
        ],
        if (t.isForeign && t.homeMinor == null) ...[
          const SizedBox(height: 14),
          Center(
            child: Text(
              'Paid in ${t.currency}. Your team adds the rupee amount on the web.',
              style: context.text.bodySmall?.copyWith(color: context.colors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        const SizedBox(height: 12),
        SectionHeader('Sources (${sources.length})'),
        for (final s in sources) _SourceCard(message: s),
        _TransactionFeedUploadSection(id: id),
      ],
    );
  }
}

class _TransactionFeedUploadSection extends ConsumerWidget {
  const _TransactionFeedUploadSection({required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teamId = ref.watch(accountProvider.select((state) => state.profile?.teamId));
    if (teamId == null) return const SizedBox.shrink();
    final key = (teamId: teamId, transactionId: id);
    final upload = ref.watch(feedUploadForTransactionProvider(key));
    return upload.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: LinearProgressIndicator(),
      ),
      error: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Joint Journey sync'),
          const Text('Could not load this transaction’s feed status.'),
          TextButton(onPressed: () => ref.invalidate(feedUploadForTransactionProvider(key)), child: const Text('Try again')),
        ],
      ),
      data: (summary) => summary == null
          ? const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader('Joint Journey sync'),
                Text('No feed upload record is saved for this transaction.'),
              ],
            )
          : _FeedUploadDetails(summary: summary),
    );
  }
}

class _FeedUploadDetails extends StatelessWidget {
  const _FeedUploadDetails({required this.summary});

  final FeedUploadSummary summary;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SectionHeader('Joint Journey sync'),
      AppCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(child: FeedUploadStatusIndicator(summary: summary)),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat('d MMM yyyy, HH:mm').format(summary.uploadedAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            _FeedDetailLine(label: 'Server status', value: summary.status),
            _FeedDetailLine(label: 'Server row ID', value: summary.serverId?.toString() ?? 'Not returned'),
            _FeedDetailLine(label: 'App version', value: summary.appVersion),
            if (summary.reason != null && summary.reason!.isNotEmpty)
              _FeedDetailLine(label: 'Server reason', value: summary.reason!),
            _SentPayloadExpansion(summary: summary),
          ],
        ),
      ),
    ],
  );
}

class _FeedDetailLine extends StatelessWidget {
  const _FeedDetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: SelectableText(value, style: Theme.of(context).textTheme.bodySmall)),
      ],
    ),
  );
}

class _SentPayloadExpansion extends ConsumerStatefulWidget {
  const _SentPayloadExpansion({required this.summary});

  final FeedUploadSummary summary;

  @override
  ConsumerState<_SentPayloadExpansion> createState() => _SentPayloadExpansionState();
}

class _SentPayloadExpansionState extends ConsumerState<_SentPayloadExpansion> {
  Future<String?>? _payload;

  void _load() {
    setState(() {
      _payload = ref.read(databaseProvider).feedUploadPayload(widget.summary.teamId, widget.summary.clientMessageId);
    });
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    leading: const Icon(PhosphorIconsBold.eye, size: 18),
    title: const Text('See sent payload'),
    subtitle: const Text('Exact request, when available'),
    onExpansionChanged: (expanded) {
      if (expanded && _payload == null) _load();
    },
    children: [
      if (_payload == null)
        const Text('Expand to load the saved request.')
      else
        FutureBuilder<String?>(
          future: _payload,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) return const LinearProgressIndicator();
            if (snapshot.hasError) {
              return TextButton(onPressed: _load, child: const Text('Could not read payload. Try again'));
            }
            final raw = snapshot.data;
            if (raw == null) {
              return Text(
                'Exact payload was not saved for this older upload, or its details were cleared by Reset imported data.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              );
            }
            final pretty = _prettyJson(raw);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: pretty));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Payload copied')));
                      }
                    },
                    icon: const Icon(PhosphorIconsFill.copy, size: 16),
                    label: const Text('Copy JSON'),
                  ),
                ),
                SelectableText(pretty, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              ],
            );
          },
        ),
    ],
  );

  String _prettyJson(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on FormatException {
      return raw;
    }
  }
}


class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.message});
  final RawMessage message;

  @override
  Widget build(BuildContext context) {
    final icon = switch (message.source) {
      SourceKind.sms => PhosphorIconsFill.chatText,
      SourceKind.email => PhosphorIconsFill.envelopeSimple,
      SourceKind.manual => PhosphorIconsFill.pencilSimple,
      SourceKind.shortcut => PhosphorIconsFill.lightning,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: context.colors.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: context.colors.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text(message.sender, style: context.text.labelLarge)),
                if (message.parseStatus == ParseStatus.merged)
                  const InfoPill(icon: PhosphorIconsBold.gitMerge, label: 'merged', color: Palette.green),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(message.body, style: context.text.bodySmall?.copyWith(height: 1.45)),
            const SizedBox(height: 6),
            Text(
              dateTimeLabel(message.receivedAt),
              style: context.text.labelSmall?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
