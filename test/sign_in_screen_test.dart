import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/account/account_providers.dart';
import 'package:moneytrail/core/theme/app_theme.dart';
import 'package:moneytrail/features/account/sign_in_screen.dart';

/// A sign-in server stand-in: no network, and the answer is chosen by the test.
class _FakeAccount extends AccountNotifier {
  _FakeAccount(this._initial, this._answer);
  final AccountState _initial;
  final Future<String?> Function() _answer;
  final calls = <(String, String)>[];

  @override
  AccountState build() => _initial;

  @override
  Future<String?> signIn({required String email, required String password}) {
    calls.add((email, password));
    return _answer();
  }
}

void main() {
  late _FakeAccount account;

  Future<void> pumpScreen(
    WidgetTester tester, {
    Future<String?> Function()? answer,
    AccountState initial = const AccountState(),
    Size size = const Size(320, 568),
    double keyboard = 0,
  }) async {
    account = _FakeAccount(initial, answer ?? () async => null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [accountProvider.overrideWith(() => account)],
        child: MaterialApp(theme: AppTheme.dark(), home: const SignInScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('fits the smallest phone, with and without the keyboard, and scrolls to the button', (tester) async {
    await pumpScreen(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Sign in'), findsNWidgets(2), reason: 'the heading and the button');

    await pumpScreen(tester, keyboard: 300);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Sign in'),
      100,
      scrollable: find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)).first,
    );
    expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
  });

  testWidgets('shows each field problem next to its own field and sends nothing', (tester) async {
    await pumpScreen(tester);
    await tester.enterText(field('Email'), 'not-an-email');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(account.calls, isEmpty);

    // Typing clears that field's problem.
    await tester.enterText(field('Email'), 'v@example.com');
    await tester.pump();
    expect(find.text('Enter your email address.'), findsNothing);
    expect(find.text('Enter your password.'), findsOneWidget);
  });

  testWidgets('sends what was typed and shows a server error in a banner', (tester) async {
    await pumpScreen(tester, answer: () async => 'Wrong email or password.');
    await tester.enterText(field('Email'), ' v@example.com ');
    await tester.enterText(field('Password'), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(account.calls.single, (' v@example.com ', 'secret'), reason: 'the account service does the trimming');
    expect(find.text('Wrong email or password.'), findsOneWidget);
    expect(tester.widget<TextField>(field('Email')).enabled, isTrue, reason: 'ready to try again');
  });

  testWidgets('shows a clear loading state and locks the form while signing in', (tester) async {
    final answer = Completer<String?>();
    await pumpScreen(tester, answer: () => answer.future);
    await tester.enterText(field('Email'), 'v@example.com');
    await tester.enterText(field('Password'), 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pump();
    expect(find.text('Signing in…'), findsOneWidget);
    expect(tester.widget<TextField>(field('Email')).enabled, isFalse);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    answer.complete('Too many attempts. Wait a minute and try again.');
    await tester.pumpAndSettle();
    expect(find.text('Too many attempts. Wait a minute and try again.'), findsOneWidget);
    expect(find.text('Signing in…'), findsNothing);
  });

  testWidgets('says why the session ended when the server ended it', (tester) async {
    await pumpScreen(tester, initial: const AccountState(notice: 'Your session has ended. Sign in again.'));
    expect(find.text('Your session has ended. Sign in again.'), findsOneWidget);
  });

  testWidgets('the password can be shown and hidden', (tester) async {
    await pumpScreen(tester);
    expect(tester.widget<TextField>(field('Password')).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<TextField>(field('Password')).obscureText, isFalse);
  });

  testWidgets('keeps a readable column on a wide screen', (tester) async {
    await pumpScreen(tester, size: const Size(1000, 800));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(field('Email')).width, lessThanOrEqualTo(420));
  });
}
