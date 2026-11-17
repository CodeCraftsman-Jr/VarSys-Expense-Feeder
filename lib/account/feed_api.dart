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

  /// The team's feed settings (any member may read them).
  Future<FeedSettings> settings(String token) async {
    final res = await _call(() => _http.get(_base.resolve('/api/feed/settings'), headers: _auth(token)));
    return FeedSettings.fromJson(_json(res));
  }

  /// Saves the team's feed settings. Alpha only; others get 403.
  Future<FeedSettings> saveSettings(String token, FeedSettings s) async {
    final res = await _call(
      () => _http.put(
        _base.resolve('/api/feed/settings'),
        headers: {..._auth(token), 'content-type': 'application/json'},
        body: jsonEncode(s.toJson()),
      ),
    );
    return FeedSettings.fromJson(_json(res));
  }

  /// Sends up to 100 rows; returns the server's per-row answers as raw maps.
  Future<List<Map<String, Object?>>> uploadRows({
    required String token,
    required String deviceId,
    required List<Map<String, Object?>> rows,
  }) async {
    final res = await _call(
      () => _http.post(
        _base.resolve('/api/feed/rows'),
        headers: {..._auth(token), 'content-type': 'application/json', 'x-device-id': deviceId},
        body: jsonEncode({'rows': rows}),
      ),
      timeout: const Duration(seconds: 45),
    );
    final results = _json(res)['results'];
    return [for (final r in (results as List? ?? const [])) (r as Map).cast<String, Object?>()];
  }

  /// Sends up to 100 bank messages the parser could not read into a transaction, so the team keeps
  /// the original text. Returns the server's per-message answers as raw maps.
  Future<List<Map<String, Object?>>> uploadUnreadable({
    required String token,
    required String deviceId,
    required List<Map<String, Object?>> rows,
  }) async {
    final res = await _call(
      () => _http.post(
        _base.resolve('/api/feed/unreadable'),
        headers: {..._auth(token), 'content-type': 'application/json', 'x-device-id': deviceId},
        body: jsonEncode({'rows': rows}),
      ),
      timeout: const Duration(seconds: 45),
    );
    final results = _json(res)['results'];
    return [for (final r in (results as List? ?? const [])) (r as Map).cast<String, Object?>()];
  }

  /// Takes back up to 100 rows this phone sent earlier and no longer stands
  /// behind (the parser now ignores the message, or the transaction was
  /// deleted). Returns the server's per-row answers.
  Future<List<Map<String, Object?>>> withdrawRows({
    required String token,
    required String deviceId,
    required List<String> clientMessageIds,
  }) async {
    final res = await _call(
      () => _http.post(
        _base.resolve('/api/feed/rows/withdraw'),
        headers: {..._auth(token), 'content-type': 'application/json', 'x-device-id': deviceId},
        body: jsonEncode({'client_message_ids': clientMessageIds}),
      ),
      timeout: const Duration(seconds: 45),
    );
    final results = _json(res)['results'];
    return [for (final r in (results as List? ?? const [])) (r as Map).cast<String, Object?>()];
  }

  /// Reads server review decisions for rows previously uploaded by this phone.
  Future<List<Map<String, Object?>>> reviewStates({
    required String token,
    required String deviceId,
    required List<String> clientMessageIds,
    List<String> confirmedClientMessageIds = const [],
  }) async {
    final res = await _call(
      () => _http.post(
        _base.resolve('/api/feed/rows/review-state'),
        headers: {..._auth(token), 'content-type': 'application/json', 'x-device-id': deviceId},
        body: jsonEncode({
          'client_message_ids': clientMessageIds,
          'confirmed_client_message_ids': confirmedClientMessageIds,
        }),
      ),
      timeout: const Duration(seconds: 45),
    );
    final results = _json(res)['results'];
    return [for (final r in (results as List? ?? const [])) (r as Map).cast<String, Object?>()];
  }

  /// What the team decided about this phone's rows since the saved cursor (both null the first time),
  /// oldest first. Save the last row's `decided_at` and `feed_row_id` and ask again from there.
  Future<({List<Map<String, Object?>> decisions, bool hasMore})> decisions({
    required String token,
    required String deviceId,
    String? afterAt,
    int? afterId,
  }) async {
    final res = await _call(
      () => _http.post(
        _base.resolve('/api/feed/rows/decisions'),
        headers: {..._auth(token), 'content-type': 'application/json', 'x-device-id': deviceId},
        body: jsonEncode({
          'after_at': ?afterAt,
          'after_id': ?afterId,
          'limit': 200,
        }),
      ),
      timeout: const Duration(seconds: 45),
    );
    final body = _json(res);
    return (
      decisions: [for (final r in (body['decisions'] as List? ?? const [])) (r as Map).cast<String, Object?>()],
      hasMore: body['has_more'] == true,
    );
  }

  Map<String, String> _auth(String token) => {'authorization': 'Bearer $token'};

  Future<http.Response> _call(Future<http.Response> Function() send, {Duration? timeout}) async {
    final http.Response res;
    try {
      res = await send().timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw const FeedHttpException(0, 'offline', 'Joint Journey did not answer. Check your connection.');
    } on SocketException {
      throw const FeedHttpException(0, 'offline', "Can't reach Joint Journey. Check your connection.");
    } on http.ClientException {
      throw const FeedHttpException(0, 'offline', "Can't reach Joint Journey. Check your connection.");
    } on HandshakeException {
      throw const FeedHttpException(0, 'offline', 'Secure connection to Joint Journey failed.');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    final code = _code(res);
    throw FeedHttpException(res.statusCode, code, switch ((res.statusCode, code)) {
      (409, 'FEED_DISABLED') => 'Your team feed is off. An alpha can switch it on.',
      (403, 'DEVICE_REVOKED') => 'An alpha removed this phone from the team feed.',
      (403, 'NO_TEAM') => 'This account is not in a team.',
      (403, _) => 'Only an alpha can change this.',
      (401, _) => 'Joint Journey did not accept the session.',
      (404, _) => 'Joint Journey does not accept phones yet.',
      (429, _) => 'Joint Journey is busy. Trying again later.',
      (final s, _) => 'Joint Journey returned an error ($s).',
    });
  }

  static Map<String, Object?> _json(http.Response res) {
    final body = jsonDecode(res.body);
    if (body is Map) return body.cast<String, Object?>();
    throw const FeedHttpException(0, 'bad_reply', 'Unexpected reply from Joint Journey.');
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

/// A failed settings or upload call. [status] is the HTTP status (0 when the
/// server was not reached); [code] the API's stable code, or `offline`.
class FeedHttpException implements Exception {
  const FeedHttpException(this.status, this.code, this.message);
  final int status;
  final String? code;
  final String message;

  bool get offline => status == 0;

  @override
  String toString() => message;
}

/// The team's feed settings (feed plan 4.10). Funding rules are fixed in code.
class FeedSettings {
  const FeedSettings({
    required this.enabled,
    this.backfillFrom,
    this.minParserVersion = 0,
    this.rawTextRetentionDays = 90,
  });

  final bool enabled;

  /// First day whose transactions count, in the team's calendar (yyyy-mm-dd).
  final String? backfillFrom;
  final int minParserVersion;
  final int rawTextRetentionDays;

  /// [backfillFrom] as local midnight, for filtering the outbox.
  DateTime? get backfillStart => backfillFrom == null ? null : DateTime.tryParse(backfillFrom!);

  factory FeedSettings.fromJson(Map<String, Object?> j) => FeedSettings(
    enabled: j['enabled'] == true,
    backfillFrom: j['backfillFrom'] as String?,
    minParserVersion: (j['minParserVersion'] as num?)?.toInt() ?? 0,
    rawTextRetentionDays: (j['rawTextRetentionDays'] as num?)?.toInt() ?? 90,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'backfill_from': backfillFrom,
    'min_parser_version': minParserVersion,
    'raw_text_retention_days': rawTextRetentionDays,
  };

  FeedSettings copyWith({bool? enabled, String? backfillFrom}) => FeedSettings(
    enabled: enabled ?? this.enabled,
    backfillFrom: backfillFrom ?? this.backfillFrom,
    minParserVersion: minParserVersion,
    rawTextRetentionDays: rawTextRetentionDays,
  );
}
