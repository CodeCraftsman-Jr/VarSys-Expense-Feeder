import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/account/account_providers.dart';
import 'package:moneytrail/account/varsys_auth.dart';
import 'package:moneytrail/core/theme/app_theme.dart';
import 'package:moneytrail/features/account/profile_button.dart';

/// Fixed account for the widget tests: no network, no storage.
class _FixedAccount extends AccountNotifier {
  _FixedAccount(this._state);
  final AccountState _state;

  @override
  AccountState build() => _state;
}

void main() {
  Future<void> pumpHeader(WidgetTester tester, AccountState account) async {
    // A narrow phone, with the app's own theme (it gives buttons a full-width minimum size).
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith(() => _FixedAccount(account))],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: SafeArea(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [Expanded(child: Text('Activity')), ProfileButton()]),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const profile = AuthProfile(userId: 'u1', email: 'v@example.com', name: 'Vasanth', teamId: 't1', role: TeamRole.alpha);

  testWidgets('shows the member initial and opens the profile with their details', (tester) async {
    await pumpHeader(tester, const AccountState(profile: profile));
    expect(find.text('V'), findsOneWidget, reason: 'the initial is the button');

    await tester.tap(find.byType(ProfileButton));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Vasanth'), findsOneWidget);
    expect(find.textContaining('alpha'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('signed out: the button flags attention and the profile offers Sign in', (tester) async {
    await pumpHeader(tester, const AccountState());
    expect(find.bySemanticsLabel('Profile, needs attention'), findsOneWidget);

    await tester.tap(find.byType(ProfileButton));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('a notice from the server shows the attention mark', (tester) async {
    await pumpHeader(tester, const AccountState(profile: profile, notice: 'Your session ended'));
    expect(find.bySemanticsLabel('Profile, needs attention'), findsOneWidget);
  });
}
