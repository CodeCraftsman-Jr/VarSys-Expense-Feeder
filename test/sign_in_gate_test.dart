import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/account/sign_in_gate.dart';

void main() {
  String? go(String location, {bool signedIn = true, bool onboarded = true}) =>
      gateRedirect(location: location, signedIn: signedIn, onboarded: onboarded);

  group('signed out', () {
    test('every route goes to sign-in, before onboarding', () {
      for (final l in ['/', '/welcome', '/activity', '/settings', '/messages', '/budgets']) {
        expect(go(l, signedIn: false), signInPath, reason: l);
        expect(go(l, signedIn: false, onboarded: false), signInPath, reason: '$l before onboarding');
      }
    });

    test('stays on sign-in', () {
      expect(go(signInPath, signedIn: false), isNull);
      expect(go(signInPath, signedIn: false, onboarded: false), isNull);
    });
  });

  group('signed in', () {
    test('leaves sign-in for onboarding first, then the app', () {
      expect(go(signInPath, onboarded: false), '/welcome');
      expect(go(signInPath), '/');
    });

    test('onboarding rules are unchanged', () {
      expect(go('/', onboarded: false), '/welcome');
      expect(go('/welcome', onboarded: false), isNull);
      expect(go('/welcome'), '/');
      expect(go('/settings'), isNull);
    });
  });
}
