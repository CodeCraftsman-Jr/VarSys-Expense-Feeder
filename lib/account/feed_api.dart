import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

/// The Joint Journey API that receives the team feed. Override for a local
/// API with `--dart-define=JJ_API_URL=http://10.0.2.2:3002`.
const jjApiUrl = String.fromEnvironment('JJ_API_URL', defaultValue: 'https://jj-api.varsys.co.in');

/// A new random device id: 32 URL-safe characters, as the API expects
/// (`^[A-Za-z0-9_-]{16,64}$`). Made at each sign-in, forgotten at sign-out.
String newDeviceId([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url.encode(List<int>.generate(24, (_) => r.nextInt(256))).replaceAll('=', '');
}

/// Phone name and app version for the device registry (see app_info.dart).
class AppInfo {
  const AppInfo({required this.label, required this.version});
  final String label;
  final String version;
}

/// How this phone's feed registration stands.
enum DeviceStatus {
  /// Registered and active for the member's team.
  registered,

  /// An alpha (or the member) revoked this phone. Signing in again makes a new registration.
  revoked,

  /// The member is not in a team yet.
  noTeam,

  /// The Joint Journey server does not offer the feed yet (older API version).
  unavailable,

  /// Network or server error; tried again on the next refresh.
  failed,
}

class FeedApiException implements Exception {
  const FeedApiException(this.status, this.message, {this.unauthorized = false});
  final DeviceStatus status;
  final String message;

  /// The session token was refused (HTTP 401).
  final bool unauthorized;

  @override
  String toString() => message;
}

/// Client for the Joint Journey feed routes (feed plan section 11).
class JjFeedClient {
  JjFeedClient(this._http, {String baseUrl = jjApiUrl, this.timeout = const Duration(seconds: 15)})
    : _base = Uri.parse(baseUrl);

  final http.Client _http;
  final Uri _base;
  final Duration timeout;

  /// Registers this phone (or refreshes its label and version). Throws
  /// [FeedApiException] for every outcome except success.
  Future<void> registerDevice({
    required String token,
    required String deviceId,
    required AppInfo app,
  }) async {
    final http.Response res;
    try {
      res = await _http
          .post(
            _base.resolve('/api/feed/devices'),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
              'x-device-id': deviceId,
            },
            body: jsonEncode({'device_id': deviceId, 'label': app.label, 'app_version': app.version}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const FeedApiException(DeviceStatus.failed, 'Joint Journey did not answer. Check your connection.');
    } on SocketException {
      throw const FeedApiException(DeviceStatus.failed, "Can't reach Joint Journey. Check your connection.");
    } on http.ClientException {
      throw const FeedApiException(DeviceStatus.failed, "Can't reach Joint Journey. Check your connection.");
    } on HandshakeException {
      throw const FeedApiException(DeviceStatus.failed, 'Secure connection to Joint Journey failed.');
    }
    if (res.statusCode == 200 || res.statusCode == 201) return;
    throw switch ((res.statusCode, _code(res))) {
      (401, _) => const FeedApiException(
        DeviceStatus.failed,
        'Joint Journey did not accept the session.',
        unauthorized: true,
      ),
      (403, 'DEVICE_REVOKED') => const FeedApiException(
        DeviceStatus.revoked,
        'An alpha removed this phone from the team feed. Sign out and sign in again to add it back.',
      ),
      (403, 'NO_TEAM') => const FeedApiException(DeviceStatus.noTeam, 'This account is not in a team yet.'),
      (409, 'DEVICE_TAKEN') => const FeedApiException(
        DeviceStatus.failed,
        'This phone id is in use by another member. Sign out and sign in again.',
      ),
      (404, _) => const FeedApiException(
        DeviceStatus.unavailable,
        'Joint Journey does not accept phones yet. This updates on its own when the server is ready.',
      ),
      (final status, _) => FeedApiException(DeviceStatus.failed, 'Joint Journey returned an error ($status).'),
    };
  }

  static String? _code(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['code'] is String) return body['code'] as String;
    } on FormatException {
      // Not JSON.
    }
    return null;
  }
}
