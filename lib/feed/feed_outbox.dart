import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../data/db/database.dart';
import '../ingestion/parser/parsed_txn.dart';

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
  FeedOutbox(
    this.db, {
    required this.installId,
    required this.appVersion,
    required this.parserVersions,
    this.parserFor,
  });

  final AppDatabase db;

  /// Random per install, kept across sign-outs; only ever sent hashed.
  final String installId;
  final String appVersion;

  /// Current parser version per source kind.
  final Map<SourceKind, int> parserVersions;

  /// Re-reads a stored message to recover what the transaction row does not
  /// keep (whether it was a payment to a person). Null: `transfer_kind` is
  /// only `self` or `none`.
  final MessageParser Function(SourceKind source)? parserFor;

  /// Upload statuses that mean the server holds the row.
  static const delivered = {'accepted', 'already_received'};

  /// sha256 of the install id and the sorted `source:externalId` list. Stable
  /// across re-parses (it names the messages, not the transaction row) and
  /// distinct between two phones of the same member.
  static String clientMessageIdFor(String installId, Iterable<String> messageIds) {
    final sorted = messageIds.toList()..sort();
    return sha256.convert(utf8.encode('$installId|${sorted.join(',')}')).toString();
  }

  /// Rows still to send. With [resendDeliveredBefore], rows the server
  /// already has, last sent before that time, are sent again too (once, so it
  /// learns fields added later, such as original message bodies); the server answers
  /// `already_received` and fills them in. Recording the answer moves their
  /// time past the cut-off, so a run always moves on.
  Future<({List<FeedOutboxRow> rows, int pending})> pending({
    required String teamId,
    DateTime? from,
    int limit = 100,
    DateTime? resendDeliveredBefore,
  }) async {
    final uploads = {
      for (final u in await db.customSelect(
        'SELECT client_message_id, status, app_version, uploaded_at FROM feed_uploads WHERE team_id = ?',
        variables: [Variable.withString(teamId)],
        readsFrom: {db.feedUploads},
      ).get())
        u.read<String>('client_message_id'): (
          status: u.read<String>('status'),
          appVersion: u.read<String>('app_version'),
          uploadedAt: u.read<DateTime>('uploaded_at'),
        ),
    };
    final messages = await (db.select(db.rawMessages)
          ..where((m) => m.transactionId.isNotNull() & m.source.isInValues([SourceKind.sms, SourceKind.email])))
        .get();
    final byTxn = <int, List<RawMessage>>{};
    for (final m in messages) {
      byTxn.putIfAbsent(m.transactionId!, () => []).add(m);
    }
    if (byTxn.isEmpty) return (rows: const <FeedOutboxRow>[], pending: 0);
    // Upload times are stored to the whole second: compare against the
    // cut-off rounded down too, or a row recorded in the cut-off's own second
    // would look older than it and be sent again on every pass.
    final cut = resendDeliveredBefore == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(resendDeliveredBefore.millisecondsSinceEpoch ~/ 1000 * 1000);

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
      final resend = cut != null && done != null && delivered.contains(done.status) && done.uploadedAt.isBefore(cut);
      // Withdrawn earlier but produced again (e.g. a parser change undone): send it back.
      final back = done != null && done.status == 'withdrawn';
      if (done != null && !retry && !resend && !back) continue;
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
      'raw_messages': [
        for (final m in msgs)
          {
            'source': m.source.name,
            'external_id': m.externalId,
            'sender': m.sender,
            'body': m.body,
            'received_at': m.receivedAt.toUtc().toIso8601String(),
          },
      ],
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
      'transfer_kind': _transferKind(t, msgs),
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

  /// `self` (own accounts), `card_bill`, `p2p` (a payment to or from a
  /// person) or `none`. Joint Journey writes only `none` debits as expenses on
  /// its own; the rest wait until transfers are classified (feed plan 5.8).
  String _transferKind(Transaction t, List<RawMessage> msgs) {
    final text = msgs.map((m) => m.body.toLowerCase()).join(' ');
    if (t.isTransfer) {
      return RegExp(r'credit ?card|card ?bill|\bcc bill|card (?:payment|dues)').hasMatch(text) ? 'card_bill' : 'self';
    }
    final parse = parserFor;
    if (parse == null) return 'none';
    for (final m in msgs) {
      final r = parse(m.source).parse(
        RawInput(source: m.source, externalId: m.externalId, sender: m.sender, body: m.body, receivedAt: m.receivedAt),
      );
      if (r is Parsed) {
        if (r.txn.transferHint) return 'self';
        return r.txn.isPersonToPerson ? 'p2p' : 'none';
      }
    }
    return 'none';
  }

  /// Rows the server holds that no current transaction produces any more: the
  /// parser now ignores their message (a loan offer read as income), the
  /// transaction was deleted, or merging changed its message set. These are
  /// taken back with `POST /api/feed/rows/withdraw`.
  /// [delivered] is how many rows the server holds from this phone, so the
  /// caller can refuse a suspiciously large withdrawal.
  Future<({List<String> ids, int delivered})> withdrawable(String teamId) async {
    final sent = await (db.selectOnly(db.feedUploads)
          ..addColumns([db.feedUploads.clientMessageId])
          ..where(db.feedUploads.teamId.equals(teamId) & db.feedUploads.status.isIn(FeedOutbox.delivered)))
        .map((row) => row.read(db.feedUploads.clientMessageId)!)
        .get();
    if (sent.isEmpty) return (ids: const <String>[], delivered: 0);
    final current = await currentMessageIds();
    return (
      ids: [for (final id in sent) if (!current.contains(id)) id],
      delivered: sent.length,
    );
  }

  /// Previously delivered ids used to pull review outcomes on the same sync run.
  Future<List<String>> deliveredMessageIds(String teamId) => (db.selectOnly(db.feedUploads)
        ..addColumns([db.feedUploads.clientMessageId])
        ..where(db.feedUploads.teamId.equals(teamId) & db.feedUploads.status.isIn(FeedOutbox.delivered))
        ..orderBy([OrderingTerm.desc(db.feedUploads.uploadedAt)]))
      .map((row) => row.read(db.feedUploads.clientMessageId)!)
      .get();

  /// The client message id of every transaction that would be uploaded now
  /// (ignoring the backfill date).
  Future<Set<String>> currentMessageIds() async {
    final messages = await (db.select(db.rawMessages)
          ..where((m) => m.transactionId.isNotNull() & m.source.isInValues([SourceKind.sms, SourceKind.email])))
        .get();
    final byTxn = <int, List<String>>{};
    for (final m in messages) {
      byTxn.putIfAbsent(m.transactionId!, () => []).add('${m.source.name}:${m.externalId}');
    }
    if (byTxn.isEmpty) return {};
    final live = await (db.selectOnly(db.transactions)
          ..addColumns([db.transactions.id])
          ..where(db.transactions.id.isIn(byTxn.keys) & db.transactions.duplicateOfId.isNull()))
        .map((r) => r.read(db.transactions.id)!)
        .get();
    return {for (final id in live) clientMessageIdFor(installId, byTxn[id]!)};
  }

  /// Marks rows the server confirmed as withdrawn, so they are not sent again.
  Future<void> recordWithdrawn(String teamId, Iterable<String> clientMessageIds) async {
    final ids = clientMessageIds.toList();
    if (ids.isEmpty) return;
    await (db.update(db.feedUploads)
          ..where((u) => u.teamId.equals(teamId) & u.clientMessageId.isIn(ids)))
        .write(FeedUploadsCompanion(status: const Value('withdrawn'), uploadedAt: Value(DateTime.now())));
  }

  /// Records the server's answer for each sent row.
  Future<void> record(
    String teamId,
    Map<String, int> txnByCmid,
    List<FeedRowResult> results, {
    required Map<String, Map<String, Object?>> payloadByCmid,
  }) async {
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
            payloadJson: Value(payloadByCmid[r.clientMessageId] == null
                ? null
                : jsonEncode(payloadByCmid[r.clientMessageId])),
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
