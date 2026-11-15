import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moneytrail/account/account_providers.dart';
import 'package:moneytrail/account/feed_api.dart';
import 'package:moneytrail/account/varsys_auth.dart';
import 'package:moneytrail/core/secrets.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/feed/feed_outbox.dart';
import 'package:moneytrail/feed/feed_sync.dart';
import 'package:moneytrail/ingestion/ingestion_service.dart';
import 'package:moneytrail/ingestion/parser/parsed_txn.dart';
import 'package:moneytrail/ingestion/parser/sms_parser.dart';
import 'package:moneytrail/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase memoryDb() => AppDatabase(DatabaseConnection(NativeDatabase.memory()));

class MemorySecrets extends SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async =>
      value == null || value.isEmpty ? values.remove(key) : values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final t0 = DateTime(2026, 11, 5, 20, 0);

Future<void> seed(AppDatabase db) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  await IngestionService(db).ingest([
    RawInput(
      source: SourceKind.sms,
      externalId: '101',
      sender: 'VM-HDFCBK',
      body: 'Sent Rs.250.00 From HDFC Bank A/C *4521 To SWIGGY On 05/11/26 Ref 528512345678',
      receivedAt: t0,
    ),
    RawInput(
      source: SourceKind.email,
      externalId: 'e1',
      sender: 'alerts@hdfcbank.net',
      body:
          'Dear Customer, Rs.250.00 has been debited from account **4521 to VPA swiggy@icici SWIGGY on 05-11-26. '
          'Your UPI transaction reference number is 528512345678.',
      receivedAt: t0.add(const Duration(hours: 1)),
    ),
    RawInput(
      source: SourceKind.sms,
      externalId: '102',
      sender: 'VM-HDFCBK',
      body: 'Sent Rs.1200.00 From HDFC Bank A/C *4521 To BIGBASKET On 01/10/26 Ref 528599999999',
      receivedAt: DateTime(2026, 10, 1, 9),
    ),
    RawInput(source: SourceKind.sms, externalId: '103', sender: 'VM-HDFCBK', body: 'Your OTP is 123456', receivedAt: t0),
  ]);
  await db.addManual(amountMinor: 5000, direction: TxnDirection.debit, at: t0, merchant: 'Cash tea');
}

FeedOutbox outboxFor(AppDatabase db, {String app = '1.0.1+3', String install = 'install-A'}) =>
    FeedOutbox(db, installId: install, appVersion: app, parserVersions: {SourceKind.sms: 4, SourceKind.email: 1});

void main() {
  group('FeedOutbox', () {
    late AppDatabase db;
    setUp(() async {
      db = memoryDb();
      await seed(db);
    });
    tearDown(() => db.close());

    test('only SMS and email transactions, one row per merged transaction', () async {
      final p = await outboxFor(db).pending(teamId: 't1');
      expect(p.pending, 2, reason: 'SMS+email Swiggy merged into one, BigBasket; not the OTP, not the manual entry');
      final swiggy = p.rows.firstWhere((r) => r.json['amount_minor'] == 25000).json;
      expect(swiggy['message_ids'], unorderedEquals(['sms:101', 'email:e1']));
      expect(swiggy['source_kinds'], unorderedEquals(['sms', 'email']));
      expect(swiggy['occurred_at_source'], 'received');
      expect(swiggy['direction'], 'debit');
      expect(swiggy['reference'], '528512345678');
      expect(swiggy['parser_version'], 4);
      expect(swiggy['app_version'], '1.0.1+3');
      expect((swiggy['occurred_at']! as String).endsWith('Z'), isTrue);
      expect(swiggy['client_message_id'], matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('the id names the messages: same on re-run, different on another phone', () async {
      final a = (await outboxFor(db).pending(teamId: 't1')).rows.map((r) => r.clientMessageId).toSet();
      final again = (await outboxFor(db).pending(teamId: 't1')).rows.map((r) => r.clientMessageId).toSet();
      final otherPhone = (await outboxFor(db, install: 'install-B').pending(teamId: 't1')).rows.map((r) => r.clientMessageId).toSet();
      expect(again, a);
      expect(otherPhone.intersection(a), isEmpty);
      expect(FeedOutbox.clientMessageIdFor('i', ['sms:2', 'email:1']), FeedOutbox.clientMessageIdFor('i', ['email:1', 'sms:2']));
    });

    test('the backfill date leaves older transactions out', () async {
      final p = await outboxFor(db).pending(teamId: 't1', from: DateTime(2026, 11, 1));
      expect(p.pending, 1);
      expect(p.rows.single.json['amount_minor'], 25000);
    });

    test('accepted rows leave the outbox; rejected ones come back after an app update', () async {
      final box = outboxFor(db);
      final p = await box.pending(teamId: 't1');
      final txns = {for (final r in p.rows) r.clientMessageId: r.transactionId};
      await box.record('t1', txns, [
        FeedRowResult(clientMessageId: p.rows[0].clientMessageId, status: 'accepted', id: 1),
        FeedRowResult(clientMessageId: p.rows[1].clientMessageId, status: 'rejected', reason: 'bad'),
      ], payloadByCmid: {for (final r in p.rows) r.clientMessageId: r.json});
      expect((await box.pending(teamId: 't1')).pending, 0);
      expect((await outboxFor(db, app: '1.0.2+4').pending(teamId: 't1')).rows.single.clientMessageId, p.rows[1].clientMessageId);
      expect((await box.pending(teamId: 'another-team')).pending, 2, reason: 'uploads are per team');
    });

    test('transfer_kind: merchant spend none, payment to a person p2p', () async {
      await IngestionService(db).ingest([
        RawInput(
          source: SourceKind.sms,
          externalId: '201',
          sender: 'JD-SBIUPI-S',
          body: 'Dear UPI user A/C X5910 debited by 60.00 on date 05Nov26 trf to Mr K Harikrishna Refno 668397152447 If not u? call-1800111109 for other services-18001234-SBI',
          receivedAt: t0.add(const Duration(hours: 3)),
        ),
      ]);
      final box = FeedOutbox(
        db,
        installId: 'install-A',
        appVersion: '1',
        parserVersions: const {SourceKind.sms: 4},
        parserFor: (_) => const SmsParser(),
      );
      final rows = (await box.pending(teamId: 't1')).rows;
      expect(rows.firstWhere((r) => r.json['amount_minor'] == 25000).json['transfer_kind'], 'none');
      expect(rows.firstWhere((r) => r.json['amount_minor'] == 6000).json['transfer_kind'], 'p2p');
      expect(
        (await outboxFor(db).pending(teamId: 't1')).rows.every((r) => r.json['transfer_kind'] == 'none'),
        isTrue,
        reason: 'without a parser only self or none',
      );
    });

    test('a sent transaction that is deleted becomes withdrawable', () async {
      final box = outboxFor(db);
      final p = await box.pending(teamId: 't1');
      await box.record('t1', {for (final r in p.rows) r.clientMessageId: r.transactionId}, [
        for (final r in p.rows) FeedRowResult(clientMessageId: r.clientMessageId, status: 'accepted', id: 1),
      ], payloadByCmid: {for (final r in p.rows) r.clientMessageId: r.json});
      expect((await box.withdrawable('t1')).ids, isEmpty);

      final swiggy = p.rows.firstWhere((r) => r.json['amount_minor'] == 25000);
      await db.deleteTxn(swiggy.transactionId);
      final w = await box.withdrawable('t1');
      expect(w.ids, [swiggy.clientMessageId]);
      expect(w.delivered, 2);
      await box.recordWithdrawn('t1', w.ids);
      expect((await box.withdrawable('t1')).ids, isEmpty);
      expect((await box.pending(teamId: 't1')).pending, 0);
    });

    test('resendDeliveredBefore sends rows the server has once more, then moves on', () async {
      final box = outboxFor(db);
      final p = await box.pending(teamId: 't1');
      await box.record('t1', {for (final r in p.rows) r.clientMessageId: r.transactionId}, [
        for (final r in p.rows) FeedRowResult(clientMessageId: r.clientMessageId, status: 'accepted', id: 1),
      ], payloadByCmid: {for (final r in p.rows) r.clientMessageId: r.json});
      final cut = DateTime.now().add(const Duration(seconds: 1));
      final again = await box.pending(teamId: 't1', resendDeliveredBefore: cut);
      expect(again.pending, 2);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await box.record('t1', {for (final r in again.rows) r.clientMessageId: r.transactionId}, [
        for (final r in again.rows) FeedRowResult(clientMessageId: r.clientMessageId, status: 'already_received', id: 1),
      ], payloadByCmid: {for (final r in again.rows) r.clientMessageId: r.json});
      expect((await box.pending(teamId: 't1', resendDeliveredBefore: cut)).pending, 0);
    });

    test('limit 0 counts without building rows', () async {
      final p = await outboxFor(db).pending(teamId: 't1', limit: 0);
      expect(p.rows, isEmpty);
      expect(p.pending, 2);
    });
  });

  group('FeedSyncController', () {
    late AppDatabase db;
    late SharedPreferences prefs;
    late MemorySecrets secrets;
    late List<http.Request> requests;
    late bool feedOn;
    late int rowsStatus;
    late bool down;
    final reviewStates = <String, String>{};

    http.Client server() => MockClient((req) async {
      if (down && req.url.host != 'auth.varsys.co.in') throw http.ClientException('network down');
      requests.add(req);
      switch (req.url.path) {
        case '/api/auth/sign-in/email':
          return http.Response('{"token":"raw"}', 200, headers: {'set-auth-token': 'tok.sig'});
        case '/api/auth/tenant-context':
          return http.Response(jsonEncode({'userId': 'u1', 'teamId': 't1', 'role': 'alpha', 'name': 'P'}), 200);
        case '/api/feed/devices':
          return http.Response('{"id":1}', 201);
        case '/api/feed/settings':
          if (req.method == 'PUT') {
            feedOn = (jsonDecode(req.body) as Map)['enabled'] == true;
          }
          return http.Response(
            jsonEncode({'enabled': feedOn, 'backfillFrom': '2026-11-01', 'minParserVersion': 0, 'rawTextRetentionDays': 90}),
            200,
          );
        case '/api/feed/rows':
          if (!feedOn) return http.Response('{"code":"FEED_DISABLED"}', 409);
          if (rowsStatus != 200) return http.Response('{"code":"DEVICE_REVOKED"}', rowsStatus);
          final rows = (jsonDecode(req.body) as Map)['rows'] as List;
          return http.Response(
            jsonEncode({
              'results': [
                for (final (i, r) in rows.indexed) {'client_message_id': (r as Map)['client_message_id'], 'id': i + 1, 'status': 'accepted'},
              ],
            }),
            200,
          );
        case '/api/feed/rows/review-state':
          final body = jsonDecode(req.body) as Map;
          return http.Response(jsonEncode({
            'results': [
              for (final id in body['client_message_ids'] as List)
                {'client_message_id': id, 'review_state': reviewStates[id] ?? 'pending', 'reviewed_at': null},
            ],
          }), 200);
      }
      return http.Response('', 404);
    });

    Future<ProviderContainer> signedIn() async {
      final client = server();
      final c = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(secrets),
          databaseProvider.overrideWithValue(db),
          varsysAuthClientProvider.overrideWithValue(VarSysAuthClient(client)),
          jjFeedClientProvider.overrideWithValue(JjFeedClient(client)),
          appInfoProvider.overrideWithValue(() async => const AppInfo(label: 'Phone', version: '1.0.1+3')),
          unauthorizedRetryDelayProvider.overrideWithValue(Duration.zero),
        ],
      );
      addTearDown(c.dispose);
      await c.read(accountProvider.notifier).signIn(email: 'p@example.com', password: 'x');
      // Join the upload that registration started.
      await c.read(feedSyncProvider.notifier).run();
      return c;
    }

    setUp(() async {
      db = memoryDb();
      await seed(db);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      secrets = MemorySecrets();
      requests = [];
      feedOn = false;
      rowsStatus = 200;
      down = false;
      reviewStates.clear();
    });
    tearDown(() => db.close());

    test('feed off: nothing is sent, the count shows what waits', () async {
      final c = await signedIn();
      await c.read(feedSyncProvider.notifier).run();
      final s = c.read(feedSyncProvider);
      expect(s.feedOn, isFalse);
      expect(s.pending, 1, reason: 'only the November row is on or after the backfill date');
      expect(s.message, contains('feed is off'));
      expect(requests.where((r) => r.url.path == '/api/feed/rows'), isEmpty);
    });

    test('feed on: sends the waiting rows with the device header, then nothing is left', () async {
      feedOn = true;
      final c = await signedIn();
      final upload = requests.lastWhere((r) => r.url.path == '/api/feed/rows');
      expect(upload.headers['x-device-id'], secrets.values[AccountKeys.deviceId]);
      expect(upload.headers['authorization'], 'Bearer tok.sig');
      expect((jsonDecode(upload.body) as Map)['rows'], hasLength(1));
      final s = c.read(feedSyncProvider);
      expect(s.pending, 0);
      expect(s.sent, 1);
      await c.read(feedSyncProvider.notifier).run();
      expect(requests.where((r) => r.url.path == '/api/feed/rows'), hasLength(1), reason: 'nothing left to send');
    });

    test('an alpha switching the feed on sends straight away', () async {
      final c = await signedIn();
      expect(await c.read(feedSyncProvider.notifier).setTeamFeed(true), isNull);
      await c.read(feedSyncProvider.notifier).run();
      expect(c.read(feedSyncProvider).pending, 0);
    });

    test('pulls web review decisions into the matching local transaction', () async {
      feedOn = true;
      final c = await signedIn();
      final upload = (await db.select(db.feedUploads).get()).singleWhere((u) => u.transactionId != null);
      final txnId = upload.transactionId!;
      await (db.update(db.transactions)..where((t) => t.id.equals(txnId))).write(
        const TransactionsCompanion(status: Value(TxnStatus.needsReview)),
      );
      reviewStates[upload.clientMessageId] = 'confirmed';

      await c.read(feedSyncProvider.notifier).run();

      final transaction = await (db.select(db.transactions)..where((t) => t.id.equals(txnId))).getSingle();
      expect(transaction.status, TxnStatus.confirmed);
      final request = requests.lastWhere((r) => r.url.path == '/api/feed/rows/review-state');
      expect(request.headers['x-device-id'], secrets.values[AccountKeys.deviceId]);
      expect((jsonDecode(request.body) as Map)['client_message_ids'], contains(upload.clientMessageId));
    });

    test('sends phone-confirmed ids back to the server', () async {
      feedOn = true;
      final c = await signedIn();
      final upload = (await db.select(db.feedUploads).get()).firstWhere((u) => u.transactionId != null);
      await db.confirm(upload.transactionId!);

      await c.read(feedSyncProvider.notifier).run();

      final request = requests.lastWhere((r) => r.url.path == '/api/feed/rows/review-state');
      expect((jsonDecode(request.body) as Map)['confirmed_client_message_ids'], contains(upload.clientMessageId));
    });

    test('a removed phone keeps its rows waiting and says why', () async {
      feedOn = true;
      rowsStatus = 403;
      final c = await signedIn();
      final s = c.read(feedSyncProvider);
      expect(s.message, contains('removed this phone'));
      expect(await (db.select(db.feedUploads)).get(), isEmpty);
    });

    test('offline keeps the rows waiting', () async {
      feedOn = true;
      final c = await signedIn();
      // A new message arrives while offline.
      await IngestionService(db).ingest([
        RawInput(
          source: SourceKind.sms,
          externalId: '104',
          sender: 'VM-HDFCBK',
          body: 'Sent Rs.99.00 From HDFC Bank A/C *4521 To ZOMATO On 06/11/26 Ref 528511111111',
          receivedAt: t0.add(const Duration(days: 1)),
        ),
      ]);
      down = true;
      await c.read(feedSyncProvider.notifier).run();
      expect(c.read(feedSyncProvider).offline, isTrue);
      expect(c.read(feedSyncProvider).message, contains('connection'));
      down = false;
      await c.read(feedSyncProvider.notifier).run();
      expect(c.read(feedSyncProvider).pending, 0, reason: 'sent once back online');
    });
  });

  group('FeedSyncController corrections', () {
    late AppDatabase db;
    late SharedPreferences prefs;
    late MemorySecrets secrets;
    late List<http.Request> requests;

    http.Client server() => MockClient((req) async {
      requests.add(req);
      switch (req.url.path) {
        case '/api/auth/sign-in/email':
          return http.Response('{"token":"raw"}', 200, headers: {'set-auth-token': 'tok.sig'});
        case '/api/auth/tenant-context':
          return http.Response(jsonEncode({'userId': 'u1', 'teamId': 't1', 'role': 'alpha', 'name': 'P'}), 200);
        case '/api/feed/devices':
          return http.Response('{"id":1}', 201);
        case '/api/feed/settings':
          return http.Response(
            jsonEncode({'enabled': true, 'backfillFrom': null, 'minParserVersion': 0, 'rawTextRetentionDays': 90}),
            200,
          );
        case '/api/feed/rows':
          final rows = (jsonDecode(req.body) as Map)['rows'] as List;
          return http.Response(
            jsonEncode({
              'results': [
                for (final r in rows) {'client_message_id': (r as Map)['client_message_id'], 'id': 1, 'status': 'accepted'},
              ],
            }),
            200,
          );
        case '/api/feed/rows/review-state':
          return http.Response('{"results":[]}', 200);
        case '/api/feed/rows/withdraw':
          final ids = (jsonDecode(req.body) as Map)['client_message_ids'] as List;
          return http.Response(
            jsonEncode({
              'results': [for (final id in ids) {'client_message_id': id, 'status': 'withdrawn'}],
            }),
            200,
          );
      }
      return http.Response('', 404);
    });

    Future<ProviderContainer> signedIn() async {
      final client = server();
      final c = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          secretStoreProvider.overrideWithValue(secrets),
          databaseProvider.overrideWithValue(db),
          varsysAuthClientProvider.overrideWithValue(VarSysAuthClient(client)),
          jjFeedClientProvider.overrideWithValue(JjFeedClient(client)),
          appInfoProvider.overrideWithValue(() async => const AppInfo(label: 'Phone', version: '1.0.1+3')),
          unauthorizedRetryDelayProvider.overrideWithValue(Duration.zero),
        ],
      );
      addTearDown(c.dispose);
      await c.read(accountProvider.notifier).signIn(email: 'p@example.com', password: 'x');
      await c.read(feedSyncProvider.notifier).run();
      return c;
    }

    setUp(() async {
      db = memoryDb();
      await seed(db);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      secrets = MemorySecrets();
      requests = [];
    });
    tearDown(() => db.close());

    test('a deleted transaction is taken back from Joint Journey once', () async {
      final c = await signedIn();
      expect(requests.where((r) => r.url.path == '/api/feed/rows/withdraw'), isEmpty);
      expect(await db.select(db.feedUploads).get(), hasLength(2));
      final txns = await db.select(db.transactions).get();
      await db.deleteTxn(txns.firstWhere((t) => t.amountMinor == 25000).id);

      await c.read(feedSyncProvider.notifier).run();
      final w = requests.where((r) => r.url.path == '/api/feed/rows/withdraw').toList();
      expect(w, hasLength(1));
      expect((jsonDecode(w.single.body) as Map)['client_message_ids'] as List, hasLength(1));
      final statuses = {for (final u in await db.select(db.feedUploads).get()) u.status};
      expect(statuses, containsAll(['accepted', 'withdrawn']));

      await c.read(feedSyncProvider.notifier).run();
      expect(requests.where((r) => r.url.path == '/api/feed/rows/withdraw'), hasLength(1), reason: 'not sent twice');
    });

    test('rows sent before transfer_kind existed are sent again once', () async {
      final c = await signedIn();
      final firstUploads = requests.where((r) => r.url.path == '/api/feed/rows').length;
      // An install that synced before this version.
      await prefs.remove(FeedPrefKeys.transferKindSent);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await c.read(feedSyncProvider.notifier).run();
      final resent = requests.where((r) => r.url.path == '/api/feed/rows').skip(firstUploads).toList();
      expect(resent, hasLength(1));
      expect((jsonDecode(resent.single.body) as Map)['rows'] as List, hasLength(2));
      expect(prefs.getBool(FeedPrefKeys.transferKindSent), isTrue);
      await c.read(feedSyncProvider.notifier).run();
      expect(requests.where((r) => r.url.path == '/api/feed/rows'), hasLength(firstUploads + 1));
    });
  });
}
