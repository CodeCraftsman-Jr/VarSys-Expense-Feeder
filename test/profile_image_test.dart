import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:moneytrail/account/varsys_auth.dart';
import 'package:moneytrail/core/theme/app_theme.dart';
import 'package:moneytrail/features/account/profile_avatar.dart';

const _photo = 'https://files.varsys.co.in/buckets/user-avatars/abc.jpg';
const _context = {'userId': 'u1', 'email': 'v@example.com', 'name': 'Vasanth', 'teamId': 't1', 'role': 'alpha'};

/// A sign-in server that answers the two calls profile() makes.
MockClient _server({Object? sessionImage = _photo, int sessionStatus = 200, Map<String, Object?> context = _context, List<String>? log}) {
  return MockClient((req) async {
    log?.add(req.url.path);
    switch (req.url.path) {
      case '/api/auth/tenant-context':
        return http.Response(jsonEncode(context), 200);
      case '/api/auth/get-session':
        return http.Response(jsonEncode({'user': {'id': 'u1', 'image': sessionImage}}), sessionStatus);
    }
    return http.Response('', 404);
  });
}

void main() {
  group('profile photo from the sign-in session', () {
    test('is read from the session user', () async {
      final profile = await VarSysAuthClient(_server()).profile('tok');
      expect(profile.image, _photo);
      expect(profile.name, 'Vasanth');
    });

    test('a member without a photo has none', () async {
      expect((await VarSysAuthClient(_server(sessionImage: null)).profile('tok')).image, isNull);
    });

    test('a failing session call never fails the sign-in', () async {
      final profile = await VarSysAuthClient(_server(sessionStatus: 500)).profile('tok');
      expect(profile.image, isNull);
      expect(profile.userId, 'u1');
    });

    test('only plain https links are ever used', () async {
      for (final bad in ['http://files.varsys.co.in/a.jpg', 'data:image/png;base64,AAAA', 'file:///sdcard/a.jpg', 'javascript:alert(1)', 'not a url', 42]) {
        expect((await VarSysAuthClient(_server(sessionImage: bad)).profile('tok')).image, isNull, reason: '$bad');
      }
    });

    test('a photo already in the team context skips the second call', () async {
      final log = <String>[];
      final profile = await VarSysAuthClient(_server(context: {..._context, 'image': _photo}, log: log)).profile('tok');
      expect(profile.image, _photo);
      expect(log, ['/api/auth/tenant-context']);
    });

    test('is kept in the cached profile, and old caches without it still load', () {
      final round = AuthProfile.fromJson(const AuthProfile(userId: 'u1', email: null, name: 'V', teamId: 't', role: TeamRole.alpha, image: _photo).toJson());
      expect(round.image, _photo);
      expect(AuthProfile.fromJson(const {'userId': 'u1', 'teamId': 't', 'role': 'alpha'}).image, isNull);
    });
  });

  group('ProfileAvatar', () {
    Future<void> pump(WidgetTester tester, AuthProfile? profile) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: Center(child: ProfileAvatar(profile: profile, size: 52))),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('keeps the initial when the photo cannot load', (tester) async {
      await pump(tester, const AuthProfile(userId: 'u1', email: null, name: 'Vasanth', teamId: 't', role: TeamRole.alpha, image: _photo));
      expect(tester.takeException(), isNull);
      expect(find.text('V'), findsOneWidget);
    });

    testWidgets('shows the initial with no photo, and a person icon with no name', (tester) async {
      await pump(tester, const AuthProfile(userId: 'u1', email: null, name: 'Gokul', teamId: 't', role: TeamRole.gamma));
      expect(find.text('G'), findsOneWidget);
      await pump(tester, null);
      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });
  });
}
