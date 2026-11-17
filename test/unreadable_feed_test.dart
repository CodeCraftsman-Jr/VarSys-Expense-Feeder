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
import 'package:moneytrail/feed/unreadable_outbox.dart';
import 'package:moneytrail/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppDatabase memoryDb() => AppDatabase(DatabaseConnection(NativeDatabase.memory()));

class _Secrets extends SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async =>
      value == null || value.isEmpty ? values.remove(key) : values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

final _t0 = DateTime(2026, 11, 5, 20, 0);

Future<void> _addUnreadable(
  AppDatabase db,
  String id, {
  String body = 'Rs. was spent on your card ending 4521',
  DateTime? at,
  ParseStatus status = ParseStatus.pendingLlm,
  SourceKind source = SourceKind.sms,
}) => db.into(db.rawMessages).insert(
  RawMessagesCompanion.insert(
    source: source,
    externalId: id,
    sender: 'VM-HDFCBK',
    body: body,
    receivedAt: at ?? _t0,
    parseStatus: status,
    ignoreReason: const Value('Could not read amount'),
  ),
);

UnreadableOutbox _box(AppDatabase db, {String app = '1.0.4+6', String install = 'install-A'}) =>
    UnreadableOutbox(db, installId: install, appVersion: app, parserVersions: {SourceKind.sms: 4, SourceKind.email: 1});

void main() {
  group('UnreadableOutbox', () {
    late AppDatabase db;
    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = memoryDb();
    });
    tearDown(() => db.close());

    test('sends only unreadable messages, with the original text and why', () async {
      await _addUnreadable(db, '1');
      await _addUnreadable(db, '2', status: ParseStatus.ignored);
      await _addUnreadable(db, '3', status: ParseStatus.parsed);
      final batch = await _box(db).pending(teamId: 't1');
      expect(batch.rows, hasLength(1));
      expect(batch.pending, 1);
      final row = batch.rows.single.json;
      expect(row['source'], 'sms');
      expect(row['external_id'], '1');
      expect(row['body'], 'Rs. was spent on your card ending 4521');
      expect(row['reason'], 'Could not read amount');
      expect(row['parser_version'], 4);
      expect(row['client_message_id'], matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('the id is stable, per install, and never equal to a transaction id', () {
      final a = UnreadableOutbox.clientMessageIdFor('install-A', 'sms', '1');
      expect(a, UnreadableOutbox.clientMessageIdFor('install-A', 'sms', '1'));
      expect(a, isNot(UnreadableOutbox.clientMessageIdFor('install-B', 'sms', '1')));
      expect(a, isNot(FeedOutbox.clientMessageIdFor('install-A', ['sms:1'])));
    });

    test('the backfill date and empty bodies leave messages out', () async {
      await _addUnreadable(db, 'old', at: DateTime(2026, 10, 1));
      await _addUnreadable(db, 'blank', body: '   ');
      await _addUnreadable(db, 'new');
      final batch = await _box(db).pending(teamId: 't1', from: DateTime(2026, 11, 1));
      expect([for (final r in batch.rows) r.json['external_id']], ['new']);
    });

    test('a stored message is not sent again; a rejected one returns after an update', () async {
      await _addUnreadable(db, '1');
      await _addUnreadable(db, '2');
      final first = await _box(db).pending(teamId: 't1');
      await _box(db).record('t1', [
        {'client_message_id': first.rows[0].clientMessageId, 'status': 'accepted', 'id': 7},
        {'client_message_id': first.rows[1].clientMessageId, 'status': 'rejected', 'reason': 'body: too long'},
      ]);
      expect((await _box(db).pending(teamId: 't1')).rows, isEmpty, reason: 'rejected stays put on the same version');
      final later = await _box(db, app: '1.0.5+7').pending(teamId: 't1');
      expect([for (final r in later.rows) r.json['external_id']], ['2']);
    });

    test('recorded uploads never look like delivered transactions', () async {
      await _addUnreadable(db, '1');
      final batch = await _box(db).pending(teamId: 't1');
      await _box(db).record('t1', [
        {'client_message_id': batch.rows.single.clientMessageId, 'status': 'already_received', 'id': 1},
      ]);
      final outbox = FeedOutbox(
        db,
        installId: 'install-A',
        appVersion: '1.0.4+6',
        parserVersions: {SourceKind.sms: 4, SourceKind.email: 1},
      );
      final withdrawable = await outbox.withdrawable('t1');
      expect(withdrawable.ids, isEmpty, reason: 'withdraw would otherwise take back every unreadable message');
      expect(withdrawable.delivered, 0);
      expect(await outbox.deliveredMessageIds('t1'), isEmpty);
    });

    test('a message that parses later is no longer unreadable', () async {
      await _addUnreadable(db, '1');
      await (db.update(db.rawMessages)..where((m) => m.externalId.equals('1')))
          .write(const RawMessagesCompanion(parseStatus: Value(ParseStatus.parsed)));
      expect((await _box(db).pending(teamId: 't1')).rows, isEmpty);
    });
  });

  group('FeedSyncController sends unreadable messages', () {
    late AppDatabase db;
    late SharedPreferences prefs;
    late _Secrets secrets;
    late List<http.Request> requests;
    late int unreadableStatus;

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
            jsonEncode({'enabled': true, 'backfillFrom': '2026-11-01', 'minParserVersion': 0, 'rawTextRetentionDays': 90}),
            200,
          );
        case '/api/feed/rows':
          return http.Response(jsonEncode({'results': []}), 200);
        case '/api/feed/rows/decisions':
          return http.Response(jsonEncode({'decisions': [], 'has_more': false}), 200);
        case '/api/feed/rows/withdraw':
          return http.Response(jsonEncode({'results': []}), 200);
        case '/api/feed/unreadable':
          if (unreadableStatus != 200) return http.Response('{"code":"X"}', unreadableStatus);
          final rows = (jsonDecode(req.body) as Map)['rows'] as List;
          return http.Response(
            jsonEncode({
              'results': [
                for (final (i, r) in rows.indexed)
                  {'client_message_id': (r as Map)['client_message_id'], 'id': i + 1, 'status': 'accepted'},
              ],
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
          appInfoProvider.overrideWithValue(() async => const AppInfo(label: 'Phone', version: '1.0.4+6')),
          unauthorizedRetryDelayProvider.overrideWithValue(Duration.zero),
        ],
      );
      addTearDown(c.dispose);
      await c.read(accountProvider.notifier).signIn(email: 'p@example.com', password: 'x');
      await c.read(feedSyncProvider.notifier).run();
      return c;
    }

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = memoryDb();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      secrets = _Secrets();
      requests = [];
      unreadableStatus = 200;
    });
    tearDown(() => db.close());

    List<http.Request> uploads() => requests.where((r) => r.url.path == '/api/feed/unreadable').toList();

    test('uploads them once with the device header, and never withdraws them', () async {
      await _addUnreadable(db, '1', at: _t0);
      await _addUnreadable(db, '2', at: _t0.add(const Duration(hours: 1)));
      final c = await signedIn();
      expect(uploads(), hasLength(1));
      final sent = (jsonDecode(uploads().single.body) as Map)['rows'] as List;
      expect(sent, hasLength(2));
      expect(uploads().single.headers['x-device-id'], secrets.values[AccountKeys.deviceId]);
      expect(uploads().single.headers['authorization'], 'Bearer tok.sig');

      await c.read(feedSyncProvider.notifier).run();
      expect(uploads(), hasLength(1), reason: 'stored messages are not sent again');
      expect(requests.where((r) => r.url.path == '/api/feed/rows/withdraw'), isEmpty);
    });

    test('a server without the endpoint does not stop the sync, and they go once it exists', () async {
      await _addUnreadable(db, '1');
      unreadableStatus = 404;
      final c = await signedIn();
      expect(c.read(feedSyncProvider).message, isNull, reason: 'the transaction upload carried on');
      expect(c.read(feedSyncProvider).lastRun, isNotNull);
      final failed = uploads().length;
      expect(failed, greaterThan(0));

      unreadableStatus = 200;
      await c.read(feedSyncProvider.notifier).run();
      final afterFix = uploads().length;
      expect(afterFix, greaterThan(failed), reason: 'tried again and stored');
      await c.read(feedSyncProvider.notifier).run();
      expect(uploads(), hasLength(afterFix), reason: 'sent once, then recorded');
    });

    test('nothing unreadable means no extra request', () async {
      await signedIn();
      expect(uploads(), isEmpty);
    });
  });
}
