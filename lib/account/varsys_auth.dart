import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The central VarSys auth-service (Better Auth), shared with Joint Journey,
/// CookSuite and the other VarSys apps. Override for a local auth-service with
/// `--dart-define=VARSYS_AUTH_URL=http://10.0.2.2:3000`.
const varsysAuthUrl = String.fromEnvironment('VARSYS_AUTH_URL', defaultValue: 'https://auth.varsys.co.in');

/// Team role in Joint Journey, as the auth-service resolves it.
enum TeamRole {
  alpha,
  beta,
  gamma;

  static TeamRole parse(String? raw) => switch (raw) {
    'alpha' || 'owner' || 'admin' => alpha,
    'beta' || 'editor' => beta,
    _ => gamma,
  };
}

/// Who is signed in, from `/api/auth/tenant-context`. Team and role are
/// derived on the server from the verified session, never chosen here.
class AuthProfile {
  const AuthProfile({
    required this.userId,
    required this.email,
    required this.name,
    required this.teamId,
    required this.role,
    this.image,
  });

  final String userId;
  final String? email;
  final String? name;

  /// The member's profile photo: an https link from the sign-in session, null when they have none.
  final String? image;

  /// Empty when the account belongs to no team yet.
  final String teamId;
  final TeamRole role;

  bool get hasTeam => teamId.isNotEmpty;

  AuthProfile withImage(String? image) =>
      AuthProfile(userId: userId, email: email, name: name, teamId: teamId, role: role, image: image);

  /// Only a plain https link is ever loaded as a photo (never http, data: or file: links).
  static String? safeImage(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty ? uri.toString() : null;
  }

  factory AuthProfile.fromJson(Map<String, Object?> j) => AuthProfile(
    userId: j['userId']! as String,
    email: j['email'] as String?,
    name: j['name'] as String?,
    teamId: (j['teamId'] as String?) ?? '',
    role: TeamRole.parse(j['role'] as String?),
    image: safeImage(j['image']),
  );

  Map<String, Object?> toJson() => {
    'userId': userId,
    'email': email,
    'name': name,
    'teamId': teamId,
    'role': role.name,
    'image': image,
  };
}

enum AuthFailure { badCredentials, unauthorized, rateLimited, offline, server }

/// A failed auth call. [message] is user-facing.
class AuthException implements Exception {
  const AuthException(this.failure, this.message);
  final AuthFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// Plain HTTP client for the Better Auth endpoints this app needs.
///
/// The app is a native client, so it sends no cookie and no Origin header:
/// Better Auth only enforces its origin check on requests that carry a
/// cookie, and the bearer plugin turns `Authorization: Bearer` into the
/// session for every other call.
class VarSysAuthClient {
  VarSysAuthClient(this._http, {String baseUrl = varsysAuthUrl, this.timeout = const Duration(seconds: 15)})
    : _base = Uri.parse(baseUrl);

  final http.Client _http;
  final Uri _base;
  final Duration timeout;

  Uri _url(String path) => _base.resolve(path);

  /// Signs in with email and password and returns the bearer session token.
  Future<String> signIn({required String email, required String password}) async {
    final res = await _send(
      () => _http.post(
        _url('/api/auth/sign-in/email'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password, 'rememberMe': true}),
      ),
    );
    if (res.statusCode == 200) {
      // The bearer plugin returns the signed token in this header; the body's
      // `token` is the unsigned form, which the plugin also accepts.
      final token = res.headers['set-auth-token'] ?? _bodyField(res, 'token');
      if (token != null && token.isNotEmpty) return token;
      throw const AuthException(AuthFailure.server, 'The sign-in server sent no session. Try again.');
    }
    throw _failure(res, signingIn: true);
  }

  /// Who the token belongs to, with team and role.
  Future<AuthProfile> profile(String token) async {
    final res = await _send(() => _http.get(_url('/api/auth/tenant-context'), headers: _bearer(token)));
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      if (body is Map<String, Object?> && body['userId'] is String) {
        final profile = AuthProfile.fromJson(body);
        // The photo lives on the session user, not in the team context.
        return profile.image != null ? profile : profile.withImage(await _sessionImage(token));
      }
      throw const AuthException(AuthFailure.server, 'Unexpected reply from the sign-in server.');
    }
    throw _failure(res, signingIn: false);
  }

  /// The signed-in member's photo link, from Better Auth's session. Best effort: a missing photo or
  /// any failure just means the initial is shown, never a failed sign-in.
  Future<String?> _sessionImage(String token) async {
    try {
      final res = await _send(() => _http.get(_url('/api/auth/get-session'), headers: _bearer(token)));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      final user = body is Map ? body['user'] : null;
      return user is Map ? AuthProfile.safeImage(user['image']) : null;
    } on AuthException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Ends the session on the server. Best effort: the token is forgotten
  /// locally either way.
  Future<void> signOut(String token) async {
    try {
      await _send(
        () => _http.post(
          _url('/api/auth/sign-out'),
          headers: {..._bearer(token), 'content-type': 'application/json'},
          body: '{}',
        ),
      );
    } on AuthException {
      // Offline or already expired: nothing more to do.
    }
  }

  Map<String, String> _bearer(String token) => {'authorization': 'Bearer $token'};

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      throw const AuthException(AuthFailure.offline, 'The sign-in server did not answer. Check your connection.');
    } on SocketException {
      throw const AuthException(AuthFailure.offline, "Can't reach the sign-in server. Check your connection.");
    } on http.ClientException {
      throw const AuthException(AuthFailure.offline, "Can't reach the sign-in server. Check your connection.");
    } on HandshakeException {
      throw const AuthException(AuthFailure.offline, 'Secure connection to the sign-in server failed.');
    }
  }

  AuthException _failure(http.Response res, {required bool signingIn}) {
    final code = _bodyField(res, 'code');
    return switch (res.statusCode) {
      401 when signingIn => const AuthException(AuthFailure.badCredentials, 'Wrong email or password.'),
      401 => const AuthException(AuthFailure.unauthorized, 'Your session has ended. Sign in again.'),
      403 when code == 'EMAIL_NOT_VERIFIED' => const AuthException(
        AuthFailure.badCredentials,
        'Verify your email address first, then sign in.',
      ),
      429 => const AuthException(AuthFailure.rateLimited, 'Too many attempts. Wait a minute and try again.'),
      _ => AuthException(AuthFailure.server, 'The sign-in server returned an error (${res.statusCode}).'),
    };
  }

  static String? _bodyField(http.Response res, String key) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body[key] is String) return body[key] as String;
    } on FormatException {
      // Not JSON.
    }
    return null;
  }
}
