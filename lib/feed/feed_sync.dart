import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../account/account_providers.dart';
import '../account/feed_api.dart';
import '../ingestion/email/email_sync.dart' show emailParserVersion;
import '../data/db/database.dart' show FeedDecisionRow;
import '../data/db/tables.dart';
import '../providers.dart';
import 'feed_outbox.dart';
import 'unreadable_outbox.dart';

abstract final class FeedPrefKeys {
  /// Random per install, kept across sign-outs; hashed into every
  /// client_message_id so two phones of one member never collide.
  static const installId = 'feed.install_id';

  /// Set once every row sent before the full source-message payload existed
  /// was sent again with it.
  static const fullMessagesSent = 'feed.full_messages_sent';

  /// Where the last decisions pull stopped, per team: "decided_at|feed_row_id".
  static const decisionCursor = 'feed.decision_cursor';
  @Deprecated('The one-time resend now refreshes the complete message payload.')
  static const transferKindSent = fullMessagesSent;
}

class FeedSyncState {
  const FeedSyncState({
    this.running = false,
    this.settings,
    this.lastRun,
    this.sent = 0,
    this.pending,
    this.message,
    this.offline = false,
  });

  final bool running;

  /// The team's feed settings from the last run; null before the first.
  final FeedSettings? settings;
  final DateTime? lastRun;

  /// Rows the server confirmed in the last run.
  final int sent;

  /// Transactions still waiting to be sent, when known.
  final int? pending;

  /// Why the last run stopped early (feed off, offline, removed phone).
  final String? message;
  final bool offline;

  bool get feedOn => settings?.enabled ?? false;
}

final feedSyncProvider = NotifierProvider<FeedSyncController, FeedSyncState>(FeedSyncController.new);

/// Sends this phone's bank transactions to Joint Journey (feed plan 3.4).
/// Runs after every SMS sync, after the phone registers on sign-in or
/// refresh, and from the Send now button. Each run sends everything waiting,
/// in batches of 100; a row the server already has comes back
/// `already_received`, so running twice is harmless. Offline or with the team
/// feed off, nothing is lost: the rows simply stay waiting.
class FeedSyncController extends Notifier<FeedSyncState> {
  @override
  FeedSyncState build() => const FeedSyncState();

  Future<void>? _inFlight;
  bool _runAgain = false;

  /// Starts a run, or joins the one already going, so two triggers at once
  /// (SMS sync and registration) never upload the same rows twice.
  Future<void> run() {
    if (_inFlight != null) {
      _runAgain = true;
      return _inFlight!;
    }
    return _inFlight = _runUntilCaughtUp().whenComplete(() => _inFlight = null);
  }

  Future<void> _runUntilCaughtUp() async {
    var total = 0;
    do {
      _runAgain = false;
      total += await _run();
    } while (_runAgain && ref.mounted);
    // The last pass often has nothing left to send: keep what this whole call sent.
    if (ref.mounted && total > state.sent) {
      state = FeedSyncState(
        settings: state.settings,
        sent: total,
        pending: state.pending,
        lastRun: state.lastRun,
        message: state.message,
        offline: state.offline,
      );
    }
  }

  /// Set once the phone was re-registered after a "device revoked" answer, so a server that keeps
  /// saying so cannot make the phone register and upload in a circle. Cleared by a good run.
  bool _revokeRefreshed = false;

  Future<int> _run() async {
    var sent = 0;
    final account = ref.read(accountProvider);
    final profile = account.profile;
    if (profile == null || !profile.hasTeam || account.device != DeviceStatus.registered) return sent;
    final notifier = ref.read(accountProvider.notifier);
    final token = await notifier.token();
    final deviceId = await notifier.deviceId();
    if (token == null || deviceId == null || !ref.mounted) return sent;

    state = FeedSyncState(running: true, settings: state.settings, pending: state.pending, lastRun: state.lastRun);
    final client = ref.read(jjFeedClientProvider);
    FeedSettings? settings = state.settings;
    var reloadDecisions = false;
    try {
      settings = await client.settings(token);
      final outbox = await _outbox();
      // The web decides everything; the phone only reads the outcome. This is independent of the
      // team's upload switch, so rows sent earlier keep their status up to date.
      await _pullDecisionsSafely(client, profile.teamId, token, deviceId);
      if (!settings.enabled) {
        final waiting = (await outbox.pending(teamId: profile.teamId, from: settings.backfillStart, limit: 0)).pending;
        if (!ref.mounted) return sent;
        state = FeedSyncState(settings: settings, pending: waiting, lastRun: DateTime.now(),
            message: 'Your team feed is off. An alpha can switch it on.');
        return sent;
      }
      final prefs = ref.read(prefsProvider);
      final runStart = DateTime.now();
      final resendBefore = (prefs.getBool(FeedPrefKeys.fullMessagesSent) ?? false) ? null : runStart;
      // Each pass records every answer, so the next pass moves on; the cap
      // only guards against a server that never records anything.
      for (var pass = 0; pass < 200; pass++) {
        final batch = await outbox.pending(
          teamId: profile.teamId,
          from: settings.backfillStart,
          resendDeliveredBefore: resendBefore,
        );
        if (batch.rows.isEmpty) break;
        final answers = await client.uploadRows(
          token: token,
          deviceId: deviceId,
          rows: [for (final r in batch.rows) r.json],
        );
        final results = [for (final a in answers) FeedRowResult.fromJson(a)];
        await outbox.record(
          profile.teamId,
          {for (final r in batch.rows) r.clientMessageId: r.transactionId},
          results,
          payloadByCmid: {for (final r in batch.rows) r.clientMessageId: r.json},
        );
        sent += results.where((r) => r.status == 'accepted' || r.status == 'already_received').length;
        // A row the server already held may carry a decision this phone never saw (a reinstall, a
        // second phone): read every decision again once, not just the new ones.
        if (results.any((r) => r.status == 'already_received')) reloadDecisions = true;
        if (!ref.mounted) return sent;
        state = FeedSyncState(running: true, settings: settings, sent: sent, pending: batch.pending - batch.rows.length, lastRun: state.lastRun);
        if (batch.pending <= batch.rows.length) break;
      }
      if (resendBefore != null) await prefs.setBool(FeedPrefKeys.fullMessagesSent, true);
      if (reloadDecisions) {
        await prefs.remove('${FeedPrefKeys.decisionCursor}.${profile.teamId}');
        await _pullDecisionsSafely(client, profile.teamId, token, deviceId);
      }
      await _sendUnreadable(profile.teamId, token, deviceId, settings.backfillStart);
      final withdrawn = await _withdraw(outbox, profile.teamId, token, deviceId);
      final left = (await outbox.pending(teamId: profile.teamId, from: settings.backfillStart, limit: 0)).pending;
      _revokeRefreshed = false;
      if (!ref.mounted) return sent;
      state = FeedSyncState(
        settings: settings,
        sent: sent,
        pending: left,
        lastRun: DateTime.now(),
        message: withdrawn.skipped,
      );
    } on FeedHttpException catch (e) {
      if (!ref.mounted) return sent;
      state = FeedSyncState(settings: settings, sent: sent, pending: state.pending, lastRun: DateTime.now(),
          message: e.message, offline: e.offline);
      if (e.code == 'DEVICE_REVOKED' && !_revokeRefreshed) {
        _revokeRefreshed = true;
        unawaited(notifier.refresh());
      }
    }
    return sent;
  }

  /// Sends the bank messages the parser could not read, so the team keeps their text. A bonus like
  /// reading decisions: a server without the endpoint yet, or a failed call, must never stop the
  /// transaction upload. Only a removed phone is passed on.
  Future<void> _sendUnreadable(String teamId, String token, String deviceId, DateTime? from) async {
    try {
      final box = await _unreadableOutbox();
      final client = ref.read(jjFeedClientProvider);
      for (var pass = 0; pass < 50; pass++) {
        final batch = await box.pending(teamId: teamId, from: from);
        if (batch.rows.isEmpty) return;
        final answers = await client.uploadUnreadable(token: token, deviceId: deviceId, rows: [for (final r in batch.rows) r.json]);
        // An answer that records nothing would repeat the same batch forever.
        if (answers.isEmpty) return;
        await box.record(teamId, answers);
        if (!ref.mounted || batch.pending <= batch.rows.length) return;
      }
    } on FeedHttpException catch (e) {
      if (e.code == 'DEVICE_REVOKED') rethrow;
    }
  }

  /// Reading decisions is a bonus: a server that does not have it yet (an older release) or a failed
  /// read must never stop the upload that follows. A revoked phone is the one answer that matters.
  Future<void> _pullDecisionsSafely(JjFeedClient client, String teamId, String token, String deviceId) async {
    try {
      await _pullDecisions(client, teamId, token, deviceId);
    } on FeedHttpException catch (e) {
      if (e.code == 'DEVICE_REVOKED') rethrow;
    }
  }

  /// Saves what the team decided about this phone's rows. Only changes travel: the last row's
  /// time and id are kept as the cursor, and each run asks from there until nothing is left.
  Future<void> _pullDecisions(JjFeedClient client, String teamId, String token, String deviceId) async {
    final prefs = ref.read(prefsProvider);
    final key = '${FeedPrefKeys.decisionCursor}.$teamId';
    var cursor = prefs.getString(key);
    // Capped so a server that keeps saying "more" cannot hold the sync forever.
    for (var page = 0; page < 100; page++) {
      final cut = cursor?.lastIndexOf('|') ?? -1;
      final answer = await client.decisions(
        token: token,
        deviceId: deviceId,
        afterAt: cut > 0 ? cursor!.substring(0, cut) : null,
        afterId: cut > 0 ? int.tryParse(cursor!.substring(cut + 1)) : null,
      );
      if (answer.decisions.isEmpty) return;
      await ref.read(databaseProvider).applyFeedDecisions(teamId, [
        for (final d in answer.decisions)
          FeedDecisionRow(
            clientMessageId: d['client_message_id'] as String,
            reviewState: d['review_state'] as String,
            category: d['category'] as String?,
            subCategory: d['sub_category'] as String?,
            decidedAt: DateTime.parse(d['decided_at'] as String),
          ),
      ]);
      final last = answer.decisions.last;
      cursor = '${last['decided_at']}|${last['feed_row_id']}';
      await prefs.setString(key, cursor);
      if (!answer.hasMore) return;
    }
  }

  /// Takes back rows the server holds that this phone no longer produces (a
  /// message the parser now ignores, a deleted transaction). Skipped while an
  /// SMS import is rebuilding transactions, and refused when it would take
  /// back more than a quarter of everything sent: that points at a local
  /// problem, not at corrections.
  Future<({int count, String? skipped})> _withdraw(
    FeedOutbox outbox,
    String teamId,
    String token,
    String deviceId,
  ) async {
    if (ref.read(smsSyncProvider).running) return (count: 0, skipped: null);
    final (:ids, :delivered) = await outbox.withdrawable(teamId);
    if (ids.isEmpty) return (count: 0, skipped: null);
    if (ids.length > 20 && ids.length * 4 > delivered) {
      return (count: 0, skipped: 'Not taking back ${ids.length} of $delivered sent transactions; that looks wrong.');
    }
    final client = ref.read(jjFeedClientProvider);
    var count = 0;
    for (var i = 0; i < ids.length; i += 100) {
      final chunk = ids.sublist(i, i + 100 > ids.length ? ids.length : i + 100);
      final answers = await client.withdrawRows(token: token, deviceId: deviceId, clientMessageIds: chunk);
      final done = [
        for (final a in answers)
          if (a['status'] == 'withdrawn' || a['status'] == 'not_found') a['client_message_id'] as String,
      ];
      await outbox.recordWithdrawn(teamId, done);
      count += done.length;
    }
    return (count: count, skipped: null);
  }

  /// Alpha switch for the team feed. The feed is on by default for every
  /// team, with all SMS history; an alpha can pause it here.
  Future<String?> setTeamFeed(bool enabled) async {
    final token = await ref.read(accountProvider.notifier).token();
    if (token == null) return 'Sign in again.';
    final client = ref.read(jjFeedClientProvider);
    try {
      final current = state.settings ?? await client.settings(token);
      final saved = await client.saveSettings(token, current.copyWith(enabled: enabled));
      if (!ref.mounted) return null;
      state = FeedSyncState(settings: saved, pending: state.pending, lastRun: state.lastRun);
      if (enabled) unawaited(run());
      return null;
    } on FeedHttpException catch (e) {
      return e.message;
    }
  }

  Future<UnreadableOutbox> _unreadableOutbox() async {
    final outbox = await _outbox();
    return UnreadableOutbox(
      ref.read(databaseProvider),
      installId: outbox.installId,
      appVersion: outbox.appVersion,
      parserVersions: outbox.parserVersions,
    );
  }

  Future<FeedOutbox> _outbox() async {
    final prefs = ref.read(prefsProvider);
    var install = prefs.getString(FeedPrefKeys.installId);
    if (install == null) {
      install = newDeviceId();
      await prefs.setString(FeedPrefKeys.installId, install);
    }
    final app = await ref.read(appInfoProvider)();
    return FeedOutbox(
      ref.read(databaseProvider),
      installId: install,
      appVersion: app.version,
      parserVersions: {SourceKind.sms: smsParserVersion, SourceKind.email: emailParserVersion},
      parserFor: ref.read(ingestionProvider).parserFor,
    );
  }
}
