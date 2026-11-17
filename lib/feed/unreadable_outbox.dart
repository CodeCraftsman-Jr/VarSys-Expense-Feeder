import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../data/db/database.dart';

/// Bank messages the parser flagged as transactions but could not finish reading (no amount, or no
/// way to tell debit from credit). The phone does not decide anything about them: it sends the
/// original text so the team keeps it and can read it on the server later.
///
/// Uploads are recorded in `feed_uploads` under [sentStatus], not under the delivered statuses, so
/// the withdraw and decision logic that works on transactions never sees them.
class UnreadableOutbox {
  UnreadableOutbox(this.db, {required this.installId, required this.appVersion, required this.parserVersions});

  final AppDatabase db;
  final String installId;
  final String appVersion;
  /// Current parser version per source kind.
  final Map<SourceKind, int> parserVersions;

  /// The recorded status for a message the server holds.
  static const sentStatus = 'unreadable_sent';

  /// What the server may answer for a stored message.
  static const _stored = {'accepted', 'already_received'};

  /// Stable per message and install; distinct from every transaction id (it names no transaction).
  static String clientMessageIdFor(String installId, String source, String externalId) =>
      sha256.convert(utf8.encode('$installId|unreadable|$source:$externalId')).toString();

  /// Messages still to send, oldest first. [from] is the team's backfill date. A message the server
  /// rejected is tried again after an app update.
  Future<({List<UnreadableRow> rows, int pending})> pending({
    required String teamId,
    DateTime? from,
    int limit = 100,
  }) async {
    final query = db.select(db.rawMessages)
      ..where((m) =>
          m.parseStatus.equalsValue(ParseStatus.pendingLlm) &
          m.source.isInValues([SourceKind.sms, SourceKind.email]))
      ..orderBy([(m) => OrderingTerm.asc(m.receivedAt), (m) => OrderingTerm.asc(m.id)]);
    final messages = await query.get();
    if (messages.isEmpty) return (rows: const <UnreadableRow>[], pending: 0);

    final sent = {
      for (final u in await db.customSelect(
        'SELECT client_message_id, status, app_version FROM feed_uploads WHERE team_id = ?',
        variables: [Variable.withString(teamId)],
        readsFrom: {db.feedUploads},
      ).get())
        u.read<String>('client_message_id'): (status: u.read<String>('status'), appVersion: u.read<String>('app_version')),
    };

    final out = <UnreadableRow>[];
    var pending = 0;
    for (final m in messages) {
      if (from != null && m.receivedAt.isBefore(from)) continue;
      if (m.body.trim().isEmpty) continue;
      final cmid = clientMessageIdFor(installId, m.source.name, m.externalId);
      final done = sent[cmid];
      final retry = done != null && !(done.status == sentStatus || _stored.contains(done.status)) && done.appVersion != appVersion;
      if (done != null && !retry) continue;
      pending++;
      if (out.length >= limit) continue;
      out.add(UnreadableRow(clientMessageId: cmid, json: _row(m, cmid)));
    }
    return (rows: out, pending: pending);
  }

  Map<String, Object?> _row(RawMessage m, String cmid) => {
    'client_message_id': cmid,
    'source': m.source.name,
    'external_id': m.externalId,
    'sender': _cap(m.sender, 500),
    'body': _cap(m.body, 50000),
    'received_at': m.receivedAt.toUtc().toIso8601String(),
    'reason': m.ignoreReason == null ? null : _cap(m.ignoreReason!, 200),
    'app_version': appVersion,
    'parser_version': parserVersions[m.source] ?? 0,
  };

  static String _cap(String s, int max) => s.length <= max ? s : s.substring(0, max);

  /// Records the server's answer for each message: stored ones as [sentStatus], anything else as
  /// the server said it, so it is retried after an update.
  Future<void> record(String teamId, List<Map<String, Object?>> answers) async {
    final now = DateTime.now();
    await db.batch((b) {
      for (final a in answers) {
        final id = a['client_message_id'] as String?;
        if (id == null) continue;
        final status = (a['status'] as String?) ?? 'rejected';
        b.insert(
          db.feedUploads,
          FeedUploadsCompanion.insert(
            teamId: teamId,
            clientMessageId: id,
            status: _stored.contains(status) ? sentStatus : status,
            reason: Value(a['reason'] as String?),
            serverId: Value((a['id'] as num?)?.toInt()),
            appVersion: appVersion,
            uploadedAt: now,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }
}

class UnreadableRow {
  const UnreadableRow({required this.clientMessageId, required this.json});
  final String clientMessageId;
  final Map<String, Object?> json;
}
