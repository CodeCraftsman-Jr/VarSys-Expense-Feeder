import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moneytrail/account/account_providers.dart';
import 'package:moneytrail/account/varsys_auth.dart';
import 'package:moneytrail/core/secrets.dart';
import 'package:moneytrail/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// A stand-in for the auth-service: one account, and tenant-context answers
/// scripted per call.
class FakeAuthServer {
  final requests = <http.Request>[];
  final contextReplies = <int>[];
  var signInStatus = 200;
  var teamId = 'team-1';
  var role = 'alpha';

  MockClient get client => MockClient((req) async {
    requests.add(req);
    switch (req.url.path) {
      case '/api/auth/sign-in/email':
        if (signInStatus != 200) return http.Response('{"code":"INVALID_EMAIL_OR_PASSWORD"}', signInStatus);
        final body = jsonDecode(req.body) as Map;
        if (body['email'] != 'p1@example.com' || body['password'] != 'secret') {
          return http.Response('{"code":"INVALID_EMAIL_OR_PASSWORD"}', 401);
        }
        return http.Response('{"token":"raw","user":{}}', 200, headers: {'set-auth-token': 'signed.token'});
      case '/api/auth/tenant-context':
        final status = contextReplies.isEmpty ? 200 : contextReplies.removeAt(0);
        if (status != 200) return http.Response('{"error":"UNAUTHORIZED"}', status);
        if (req.headers['authorization'] != 'Bearer signed.token') return http.Response('{}', 401);
        return http.Response(
          jsonEncode({'userId': 'u1', 'teamId': teamId, 'role': role, 'email': 'p1@example.com', 'name': 'P One'}),
          200,
        );
      case '/api/auth/sign-out':
        return http.Response('{"success":true}', 200);
    }
    return http.Response('not found', 404);
  });
}

void main() {
  late FakeAuthServer server;
  late MemorySecrets secrets;
  late SharedPreferences prefs;

  Future<ProviderContainer> container({http.Client? client}) async {
    final c = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        secretStoreProvider.overrideWithValue(secrets),
        varsysAuthClientProvider.overrideWithValue(VarSysAuthClient(client ?? server.client)),
        unauthorizedRetryDelayProvider.overrideWithValue(Duration.zero),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() async {
    server = FakeAuthServer();
    secrets = MemorySecrets();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  group('VarSysAuthClient', () {
    test('sends no cookie or origin, and uses the set-auth-token header', () async {
      final token = await VarSysAuthClient(server.client).signIn(email: 'p1@example.com', password: 'secret');
      expect(token, 'signed.token');
      final req = server.requests.single;
      expect(req.url.toString(), 'https://auth.varsys.co.in/api/auth/sign-in/email');
      expect(req.headers.keys.map((k) => k.toLowerCase()), isNot(anyOf(contains('cookie'), contains('origin'))));
    });

    test('maps server answers to user-facing failures', () async {
      final auth = VarSysAuthClient(server.client);
      await expectLater(
        auth.signIn(email: 'p1@example.com', password: 'wrong'),
        throwsA(isA<AuthException>().having((e) => e.failure, 'failure', AuthFailure.badCredentials)),
      );
      server.signInStatus = 429;
      await expectLater(
        auth.signIn(email: 'p1@example.com', password: 'secret'),
        throwsA(isA<AuthException>().having((e) => e.failure, 'failure', AuthFailure.rateLimited)),
      );
      final offline = VarSysAuthClient(MockClient((_) async => throw http.ClientException('no route')));
      await expectLater(
        offline.profile('t'),
        throwsA(isA<AuthException>().having((e) => e.failure, 'failure', AuthFailure.offline)),
      );
    });

    test('role names from the auth-service map to alpha, beta, gamma', () {
      expect(TeamRole.parse('owner'), TeamRole.alpha);
      expect(TeamRole.parse('editor'), TeamRole.beta);
      expect(TeamRole.parse(null), TeamRole.gamma);
    });
  });

  group('AccountNotifier', () {
    test('sign-in stores the token securely and the profile in prefs', () async {
      final c = await container();
      final error = await c.read(accountProvider.notifier).signIn(email: ' p1@example.com ', password: 'secret');
      expect(error, isNull);
      final s = c.read(accountProvider);
      expect(s.profile?.teamId, 'team-1');
      expect(s.profile?.role, TeamRole.alpha);
      expect(secrets.values[AccountKeys.token], 'signed.token');
      expect(prefs.getString(AccountKeys.profile), isNot(contains('signed.token')));
    });

    test('wrong password returns a message and stores nothing', () async {
      final c = await container();
      final error = await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'nope');
      expect(error, 'Wrong email or password.');
      expect(c.read(accountProvider).signedIn, isFalse);
      expect(secrets.values, isEmpty);
    });

    test('an account with no team signs in with a notice', () async {
      server.teamId = '';
      final c = await container();
      await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      expect(c.read(accountProvider).signedIn, isTrue);
      expect(c.read(accountProvider).notice, contains('not in a Joint Journey team'));
    });

    test('one 401 is retried; the session survives', () async {
      final c = await container();
      await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      server.contextReplies.add(401);
      await c.read(accountProvider.notifier).refresh();
      expect(c.read(accountProvider).signedIn, isTrue);
      expect(secrets.values[AccountKeys.token], 'signed.token');
    });

    test('two 401s end the session', () async {
      final c = await container();
      await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      server.contextReplies.addAll([401, 401]);
      await c.read(accountProvider.notifier).refresh();
      expect(c.read(accountProvider).signedIn, isFalse);
      expect(c.read(accountProvider).notice, 'Your session has ended. Sign in again.');
      expect(secrets.values, isEmpty);
      expect(prefs.getString(AccountKeys.profile), isNull);
    });

    test('offline refresh keeps the cached profile', () async {
      final c = await container();
      await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      server.contextReplies.add(503);
      await c.read(accountProvider.notifier).refresh();
      expect(c.read(accountProvider).signedIn, isTrue);
      expect(c.read(accountProvider).offline, isTrue);
    });

    test('a restart shows the cached account before the server answers', () async {
      final first = await container();
      await first.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      final second = await container();
      expect(second.read(accountProvider).profile?.name, 'P One');
    });

    test('sign-out forgets the token and tells the server', () async {
      final c = await container();
      await c.read(accountProvider.notifier).signIn(email: 'p1@example.com', password: 'secret');
      await c.read(accountProvider.notifier).signOut();
      expect(c.read(accountProvider).signedIn, isFalse);
      expect(secrets.values, isEmpty);
      final out = server.requests.last;
      expect(out.url.path, '/api/auth/sign-out');
      expect(out.headers['authorization'], 'Bearer signed.token');
    });
  });
}
