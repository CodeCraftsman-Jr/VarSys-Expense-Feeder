import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../llm/llm_providers.dart' show httpClientProvider;
import '../providers.dart';
import 'varsys_auth.dart';

abstract final class AccountKeys {
  /// SecretStore key for the Better Auth bearer token.
  static const token = 'varsys.session_token';

  /// SharedPreferences key for the last known profile (not secret), so the
  /// account shows offline.
  static const profile = 'account.profile';
}

class AccountState {
  const AccountState({this.profile, this.checking = false, this.offline = false, this.notice});

  /// Null when signed out.
  final AuthProfile? profile;

  /// A refresh against the server is running.
  final bool checking;

  /// The last refresh could not reach the server; [profile] is the cached one.
  final bool offline;

  /// User-facing message from the last refresh (session ended, no team).
  final String? notice;

  bool get signedIn => profile != null;
}

final varsysAuthClientProvider = Provider((ref) => VarSysAuthClient(ref.watch(httpClientProvider)));

/// How long to wait before re-checking a 401. The auth-service also answers
/// 401 when its own database call times out (JJ `auth.ts` returns null on a
/// failed fetch), so one 401 alone does not end the session.
final unauthorizedRetryDelayProvider = Provider((ref) => const Duration(seconds: 5));

final accountProvider = NotifierProvider<AccountNotifier, AccountState>(AccountNotifier.new);

class AccountNotifier extends Notifier<AccountState> {
  @override
  AccountState build() {
    final cached = _readCachedProfile();
    if (cached != null) Future.microtask(refresh);
    return AccountState(profile: cached);
  }

  VarSysAuthClient get _client => ref.read(varsysAuthClientProvider);

  /// The bearer token for API calls, or null when signed out.
  Future<String?> token() => ref.read(secretStoreProvider).read(AccountKeys.token);

  /// Signs in and loads team and role. Returns an error message, or null.
  Future<String?> signIn({required String email, required String password}) async {
    try {
      final token = await _client.signIn(email: email.trim(), password: password);
      final AuthProfile profile;
      try {
        profile = await _client.profile(token);
      } on AuthException {
        await _client.signOut(token); // do not leave an unused session behind
        rethrow;
      }
      await ref.read(secretStoreProvider).write(AccountKeys.token, token);
      await _cache(profile);
      state = AccountState(profile: profile, notice: _teamNotice(profile));
      return null;
    } on AuthException catch (e) {
      return e.message;
    }
  }

  /// Re-reads team and role from the server. Keeps the cached profile when
  /// offline; signs out only after a second 401.
  Future<void> refresh() async {
    final token = await this.token();
    if (!ref.mounted) return;
    if (token == null) {
      if (state.signedIn) await _forget();
      return;
    }
    state = AccountState(profile: state.profile, checking: true);
    try {
      final profile = await _profileWithRetry(token);
      if (!ref.mounted) return;
      await _cache(profile);
      state = AccountState(profile: profile, notice: _teamNotice(profile));
    } on AuthException catch (e) {
      if (!ref.mounted) return;
      if (e.failure == AuthFailure.unauthorized) {
        await _forget(notice: e.message);
      } else {
        state = AccountState(profile: state.profile, offline: true);
      }
    }
  }

  Future<void> signOut() async {
    final token = await this.token();
    await _forget();
    if (token != null) await _client.signOut(token);
  }

  Future<AuthProfile> _profileWithRetry(String token) async {
    try {
      return await _client.profile(token);
    } on AuthException catch (e) {
      if (e.failure != AuthFailure.unauthorized) rethrow;
      await Future<void>.delayed(ref.read(unauthorizedRetryDelayProvider));
      if (!ref.mounted) rethrow;
      return _client.profile(token);
    }
  }

  Future<void> _forget({String? notice}) async {
    await ref.read(secretStoreProvider).delete(AccountKeys.token);
    await ref.read(prefsProvider).remove(AccountKeys.profile);
    state = AccountState(notice: notice);
  }

  Future<void> _cache(AuthProfile p) => ref.read(prefsProvider).setString(AccountKeys.profile, jsonEncode(p.toJson()));

  AuthProfile? _readCachedProfile() {
    final raw = ref.read(prefsProvider).getString(AccountKeys.profile);
    if (raw == null) return null;
    try {
      return AuthProfile.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  static String? _teamNotice(AuthProfile p) =>
      p.hasTeam ? null : 'This account is not in a Joint Journey team yet. Ask your team alpha to add you.';
}
