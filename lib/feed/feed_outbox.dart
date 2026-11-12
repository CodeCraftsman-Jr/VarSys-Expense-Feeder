import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../data/db/database.dart';

/// One transaction ready to send (feed plan 3.3). [json] is the API body row.
class FeedOutboxRow {
  const FeedOutboxRow({required this.transactionId, required this.clientMessageId, required this.json});
  final int transactionId;
  final String clientMessageId;
  final Map<String, Object?> json;
}

/// Which transactions still need to go to Joint Journey, built from the local
/// database on demand rather than queued at ingest. A transaction counts when
/// it came from SMS or email, is not a duplicate, is on or after the team's
/// backfill date, and has no upload record for the team (or only a rejected
/// one from an older app version).
class FeedOutbox {
  FeedOutbox(this.db, {required this.installId, required this.appVersion, required this.parserVersions});

  final AppDatabase db;

  /// Random per install, kept across sign-outs; only ever sent hashed.
  final String installId;
  final String appVersion;

  /// Current parser version per source kind.
  final Map<SourceKind, int> parserVersions;

  /// sha256 of the install id and the sorted `source:externalId` list. Stable
  /// across re-parses (it names the messages, not the transaction row) and
  /// distinct between two phones of the same member.
  static String clientMessageIdFor(String installId, Iterable<String> messageIds) {
    final sorted = messageIds.toList()..sort();
    return sha256.convert(utf8.encode('$installId|${sorted.join(',')}')).toString();
  }

  Future<({List<FeedOutboxRow> rows, int pending})> pending({
    required String teamId,
    DateTime? from,
    int limit = 100,
  }) async {
    final uploads = {
      for (final u in await (db.select(db.feedUploads)..where((u) => u.teamId.equals(teamId))).get())
        u.clientMessageId: u,
    };
    final messages = await (db.select(db.rawMessages)
          ..where((m) => m.transactionId.isNotNull() & m.source.isInValues([SourceKind.sms, SourceKind.email])))
        .get();
    final byTxn = <int, List<RawMessage>>{};
    for (final m in messages) {
      byTxn.putIfAbsent(m.transactionId!, () => []).add(m);
    }
    if (byTxn.isEmpty) return (rows: const <FeedOutboxRow>[], pending: 0);

    final query = db.select(db.transactions).join([
      leftOuterJoin(db.categories, db.categories.id.equalsExp(db.transactions.categoryId)),
      leftOuterJoin(db.accounts, db.accounts.id.equalsExp(db.transactions.accountId)),
    ])
      ..where(db.transactions.id.isIn(byTxn.keys) & db.transactions.duplicateOfId.isNull())
      ..orderBy([OrderingTerm.asc(db.transactions.occurredAt), OrderingTerm.asc(db.transactions.id)]);
    if (from != null) query.where(db.transactions.occurredAt.isBiggerOrEqualValue(from));

    final out = <FeedOutboxRow>[];
    var pending = 0;
    for (final r in await query.get()) {
      final t = r.readTable(db.transactions);
      final msgs = byTxn[t.id]!;
      final ids = [for (final m in msgs) '${m.source.name}:${m.externalId}'];
      final cmid = clientMessageIdFor(installId, ids);
      final done = uploads[cmid];
      final retry = done != null &&
          (done.status == 'rejected' || done.status == 'client_outdated') &&
          done.appVersion != appVersion;
      if (done != null && !retry) continue;
      pending++;
      if (out.length >= limit) continue;
      out.add(FeedOutboxRow(
        transactionId: t.id,
        clientMessageId: cmid,
        json: _row(t, r.readTableOrNull(db.categories), r.readTableOrNull(db.accounts), msgs, ids, cmid),
      ));
    }
    return (rows: out, pending: pending);
  }

  Map<String, Object?> _row(
    Transaction t,
    Category? category,
    Account? account,
    List<RawMessage> msgs,
    List<String> ids,
    String cmid,
  ) {
    final kinds = {for (final m in msgs) m.source};
    final hasConversion = t.convertedMinor != null && t.convertedCurrency != null && t.convertedMinor! > 0;
    return {
      'client_message_id': cmid,
      'message_ids': ids,
      'amount_minor': t.amountMinor,
      'currency': t.currency,
      'converted_minor': hasConversion ? t.convertedMinor : null,
      'converted_currency': hasConversion ? t.convertedCurrency : null,
      'direction': t.direction.name,
      'occurred_at': t.occurredAt.toUtc().toIso8601String(),
      // SMS rows carry the receive time; email-only rows the message date.
      'occurred_at_source': kinds.contains(SourceKind.sms) ? 'received' : 'email_date',
      'bank_name': _cap(account?.institution, 80),
      'account_hint': _cap(t.accountHint ?? account?.last4, 20),
      'mode': t.mode.name,
      'transfer_hint': t.isTransfer,
      'reference': _cap(t.reference, 64),
      'counterparty': _cap(t.counterparty, 200),
      'merchant': _cap(t.merchant, 200),
      'category_hint': _cap(category?.name, 80),
      'source_kinds': [for (final k in kinds) k.name],
      'needs_review': t.status == TxnStatus.needsReview,
      'app_version': appVersion,
      'parser_version': [for (final k in kinds) parserVersions[k] ?? 0].reduce((a, b) => a > b ? a : b),
    };
  }

  /// Records the server's answer for each sent row.
  Future<void> record(String teamId, Map<String, int> txnByCmid, List<FeedRowResult> results) async {
    final now = DateTime.now();
    await db.batch((b) {
      for (final r in results) {
        if (r.clientMessageId == null) continue;
        b.insert(
          db.feedUploads,
          FeedUploadsCompanion.insert(
            teamId: teamId,
            clientMessageId: r.clientMessageId!,
            transactionId: Value(txnByCmid[r.clientMessageId]),
            status: r.status,
            reason: Value(r.reason),
            serverId: Value(r.id),
            appVersion: appVersion,
            uploadedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  static String? _cap(String? s, int max) {
    final v = s?.trim();
    if (v == null || v.isEmpty) return null;
    return v.length <= max ? v : v.substring(0, max);
  }
}

/// The server's verdict on one row (`POST /api/feed/rows`).
class FeedRowResult {
  const FeedRowResult({required this.clientMessageId, required this.status, this.id, this.reason});
  final String? clientMessageId;
  final String status;
  final int? id;
  final String? reason;

  factory FeedRowResult.fromJson(Map<String, Object?> j) => FeedRowResult(
    clientMessageId: j['client_message_id'] as String?,
    status: (j['status'] as String?) ?? 'rejected',
    id: (j['id'] as num?)?.toInt(),
    reason: j['reason'] as String?,
  );
}
