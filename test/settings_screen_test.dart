import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/account/account_providers.dart';
import 'package:moneytrail/account/feed_api.dart';
import 'package:moneytrail/account/varsys_auth.dart';
import 'package:moneytrail/core/secrets.dart';
import 'package:moneytrail/core/theme/app_theme.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/feed/feed_sync.dart';
import 'package:moneytrail/features/settings/capture_rows.dart';
import 'package:moneytrail/features/settings/settings_screen.dart';
import 'package:moneytrail/features/settings/status_banner.dart';
import 'package:moneytrail/providers.dart';
import 'package:moneytrail/ingestion/sms/sms_source.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixedAccount extends AccountNotifier {
  _FixedAccount(this._state);
  final AccountState _state;
  @override
  AccountState build() => _state;
}

class _MemorySecrets extends SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String? value) async => value == null ? values.remove(key) : values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Pretends to be an Android phone without SMS permission, so no real sync starts.
class _AndroidSms extends SmsSource {
  @override
  bool get isSupported => true;
  @override
  Future<bool> hasPermission() async => false;
}

const _profile = AuthProfile(userId: 'u1', email: 'v@example.com', name: 'Vasanth', teamId: 't1', role: TeamRole.alpha);

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory()));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('moneytrail/device'),
      (call) async => switch (call.method) {
        'batteryUnrestricted' => false,
        'autostartPage' => true,
        _ => null,
      },
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('moneytrail/device'),
      null,
    );
    await db.close();
  });

  Future<ProviderContainer> pumpSettings(WidgetTester tester, {required bool smsOn, AccountState? account}) async {
    SharedPreferences.setMockInitialValues({'sms.enabled': smsOn});
    final prefs = await SharedPreferences.getInstance();
    // Tall enough that every group is built at once; narrow like a small phone.
    tester.view.physicalSize = const Size(360, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        secretStoreProvider.overrideWithValue(_MemorySecrets()),
        smsSourceProvider.overrideWithValue(_AndroidSms()),
        accountProvider.overrideWith(() => _FixedAccount(account ?? const AccountState(profile: _profile, device: DeviceStatus.registered))),
        appInfoProvider.overrideWithValue(() async => const AppInfo(label: 'Phone', version: '1.0.2+4')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.dark(), home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('every group renders without layout errors on a 360px phone', (tester) async {
    await pumpSettings(tester, smsOn: true);
    expect(tester.takeException(), isNull);
    for (final title in ['CAPTURE', 'KEEP IT RUNNING', 'LOOK', 'PRIVACY AND SECURITY', 'DATA', 'ABOUT']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    for (final row in ['SMS', 'Email', 'Instant alerts', 'Background sync', 'Autostart', 'Sync now', 'Theme', 'App lock', 'Reset imported data', 'VarSys MoneyTrail']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
  });

  testWidgets('the profile is no longer in Settings', (tester) async {
    await pumpSettings(tester, smsOn: true);
    expect(find.text('Vasanth'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
  });

  testWidgets('with SMS off it offers Connect and hides the SMS-only rows', (tester) async {
    await pumpSettings(tester, smsOn: false);
    expect(tester.takeException(), isNull);
    expect(find.text('Connect'), findsWidgets);
    expect(find.text('Instant alerts'), findsNothing);
    expect(find.text('SMS message log'), findsNothing);
    expect(find.textContaining('Nothing is being captured'), findsOneWidget, reason: 'the banner says so');
  });

  testWidgets('tapping the SMS row never turns SMS off; only its switch does', (tester) async {
    final container = await pumpSettings(tester, smsOn: true);
    await tester.tap(find.text('SMS'));
    await tester.pumpAndSettle();
    expect(container.read(smsSyncProvider).enabled, isTrue);

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(container.read(smsSyncProvider).enabled, isFalse);
  });

  testWidgets('the version shows in About', (tester) async {
    await pumpSettings(tester, smsOn: true);
    expect(find.textContaining('Version 1.0.2+4'), findsOneWidget);
  });

  group('status banner', () {
    const registered = AccountState(profile: _profile, device: DeviceStatus.registered);
    List<String> check({
      bool supported = true,
      bool smsOn = true,
      String? smsError,
      bool emailOn = false,
      AccountState account = registered,
      FeedSyncState feed = const FeedSyncState(),
    }) =>
        StatusBanner.problems(
          smsSupported: supported,
          smsEnabled: smsOn,
          smsError: smsError,
          emailEnabled: emailOn,
          account: account,
          feed: feed,
        );

    FeedSettings settings({required bool on}) =>
        FeedSettings(enabled: on, backfillFrom: '2026-11-01');

    test('is clear when everything is flowing', () {
      expect(check(feed: FeedSyncState(settings: settings(on: true), pending: 0)), isEmpty);
    });

    test('flags nothing being captured only when SMS and email are both off', () {
      expect(check(smsOn: false), isNotEmpty);
      expect(check(smsOn: false, emailOn: true), isEmpty);
      expect(check(supported: false, smsOn: false), isEmpty, reason: 'iOS has no SMS');
    });

    test('reports an SMS error, an unregistered phone, a team feed that is off, and a backlog', () {
      expect(check(smsError: 'SMS permission missing'), ['SMS: SMS permission missing']);
      expect(check(account: const AccountState(profile: _profile, device: DeviceStatus.revoked, deviceMessage: 'Removed')), ['Removed']);
      expect(check(feed: FeedSyncState(settings: settings(on: false))), ['Your team feed is off, so nothing is sent.']);
      expect(check(feed: FeedSyncState(settings: settings(on: true), pending: 4)), ['4 waiting to send.']);
    });
  });

  test('stats summary lists parsed, merged and ignored, and unreadable only when there are some', () {
    expect(statsSummary(const {}), 'Nothing read yet');
    expect(
      statsSummary({ParseStatus.parsed: 777, ParseStatus.merged: 9, ParseStatus.ignored: 1617}),
      '777 parsed · 9 merged · 1617 ignored',
    );
    expect(statsSummary({ParseStatus.parsed: 1, ParseStatus.pendingLlm: 3}), '1 parsed · 0 merged · 0 ignored · 3 unreadable');
  });
}
