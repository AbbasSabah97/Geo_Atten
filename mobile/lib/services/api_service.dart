import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;

  ApiException(this.message, [this.statusCode, this.code]);

  @override
  String toString() => message;
}

class _TransientGoogleResponse implements Exception {
  final String message;
  final int? statusCode;

  const _TransientGoogleResponse(this.message, [this.statusCode]);
}

class ApiService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'workspace_session_token';
  static const _deviceKey = 'workspace_bound_device_id';
  static const _maxTransportAttempts = 4;
  static const _maxRedirectHops = 5;

  Uri get _endpoint {
    if (!AppConfig.hasValidScriptUrl) {
      throw ApiException(
        'لم يتم إعداد رابط Google Apps Script بشكل صحيح. أعد بناء التطبيق باستخدام GOOGLE_SCRIPT_URL.',
      );
    }
    return Uri.parse(AppConfig.googleScriptUrl);
  }

  Future<Map<String, dynamic>> login({
    required String employeeCode,
    required String pin,
    required String deviceId,
  }) async {
    final data = await _post({
      'action': 'login',
      'employee_code': employeeCode.trim(),
      'pin': pin,
      'device_id': deviceId,
      'app_version': AppConfig.appVersion,
    });

    final token = data['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw ApiException('الخدمة لم ترجع جلسة دخول صالحة.');
    }

    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _deviceKey, value: deviceId);
    return data;
  }

  Future<void> logout() async {
    final token = await readToken();
    final deviceId = await _storage.read(key: _deviceKey);
    if (token != null && deviceId != null) {
      try {
        await _post({
          'action': 'logout',
          'session_token': token,
          'device_id': deviceId,
        });
      } catch (_) {}
    }
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _deviceKey);
  }

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<Map<String, dynamic>> me() async => _authorizedPost('me');

  Future<List<dynamic>> history() async {
    final data = await _authorizedPost('history');
    return (data['items'] as List<dynamic>? ?? const []);
  }

  Future<Map<String, dynamic>> punch({
    required String eventType,
    required double latitude,
    required double longitude,
    required double accuracyMeters,
    required bool isMocked,
    required String deviceId,
  }) async {
    final challenge = await _authorizedPost('challenge');
    final challengeId = challenge['challenge_id']?.toString();
    if (challengeId == null || challengeId.isEmpty) {
      throw ApiException('تعذر إنشاء التحقق الأمني للعملية. حاول مرة أخرى.');
    }

    return _authorizedPost('punch', extra: {
      'event_type': eventType,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy_meters': accuracyMeters,
      'is_mocked': isMocked,
      'device_id': deviceId,
      'challenge_id': challengeId,
      'client_time_utc': DateTime.now().toUtc().toIso8601String(),
      'app_version': AppConfig.appVersion,
    });
  }

  Future<Map<String, dynamic>> _authorizedPost(
    String action, {
    Map<String, dynamic>? extra,
  }) async {
    final token = await readToken();
    final deviceId = await _storage.read(key: _deviceKey);
    if (token == null || deviceId == null) {
      throw ApiException('انتهت جلسة الدخول.', 401, 'UNAUTHORIZED');
    }

    final payload = <String, dynamic>{
      'action': action,
      'session_token': token,
      'device_id': deviceId,
      'app_version': AppConfig.appVersion,
      ...?extra,
    };
    return _post(payload);
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> payload) async {
    final action = payload['action']?.toString() ?? 'unknown';
    _TransientGoogleResponse? lastTransient;

    for (var attempt = 1; attempt <= _maxTransportAttempts; attempt++) {
      try {
        final response = await _sendToAppsScript(payload);

        if (_isTransientStatus(response.statusCode)) {
          throw _TransientGoogleResponse(
            'HTTP ${response.statusCode}',
            response.statusCode,
          );
        }

        if (response.statusCode < 200 || response.statusCode >= 400) {
          throw ApiException(
            'تعذر الوصول إلى خدمة الحضور (${response.statusCode}).',
            response.statusCode,
          );
        }

        final data = _decode(response);
        if (data['ok'] != true) {
          final code = data['code']?.toString();
          final status = code == 'UNAUTHORIZED' ? 401 : null;
          throw ApiException(_errorMessage(data), status, code);
        }
        return data;
      } on _TransientGoogleResponse catch (e) {
        lastTransient = e;
        if (attempt == _maxTransportAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 1200 * attempt));
      } on TimeoutException {
        lastTransient = const _TransientGoogleResponse('timeout');
        if (attempt == _maxTransportAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 1200 * attempt));
      } on http.ClientException {
        lastTransient = const _TransientGoogleResponse('network error');
        if (attempt == _maxTransportAttempts) break;
        await Future<void>.delayed(Duration(milliseconds: 1200 * attempt));
      }
    }

    final statusText = lastTransient?.statusCode == null
        ? ''
        : ' HTTP ${lastTransient!.statusCode}.';
    throw ApiException(
      'تعذر استلام استجابة صالحة من Google Apps Script بعد عدة محاولات.'
      '$statusText المرحلة: $action. حاول مرة أخرى بعد لحظات.',
      lastTransient?.statusCode,
      'GOOGLE_RESPONSE_INVALID',
    );
  }

  Future<http.Response> _sendToAppsScript(Map<String, dynamic> payload) async {
    final client = http.Client();
    try {
      var response = await _sendRequest(
        client,
        method: 'POST',
        uri: _endpoint,
        body: jsonEncode(payload),
      );

      var hops = 0;
      while (_isRedirectStatus(response.statusCode)) {
        hops++;
        if (hops > _maxRedirectHops) {
          throw const _TransientGoogleResponse('redirect limit exceeded');
        }

        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw _TransientGoogleResponse(
            'redirect without location',
            response.statusCode,
          );
        }

        final baseUri = response.request?.url ?? _endpoint;
        final nextUri = baseUri.resolve(location);
        if (!_isTrustedGoogleUri(nextUri)) {
          throw ApiException('تم رفض إعادة توجيه غير موثوقة من خدمة Google.');
        }

        // Google ContentService normally redirects POST results to a one-time
        // script.googleusercontent.com URL. A redirect back to /exec is a
        // transient bounce-loop and should be retried from the start.
        if (_isAppsScriptExecUri(nextUri)) {
          throw _TransientGoogleResponse(
            'redirect bounced back to /exec',
            response.statusCode,
          );
        }

        response = await _sendRequest(
          client,
          method: 'GET',
          uri: nextUri,
        );
      }

      return response;
    } finally {
      client.close();
    }
  }

  Future<http.Response> _sendRequest(
    http.Client client, {
    required String method,
    required Uri uri,
    String? body,
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';

    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = body;
    }

    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 20));
    return http.Response.fromStream(streamed).timeout(const Duration(seconds: 20));
  }

  bool _isRedirectStatus(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  bool _isTransientStatus(int statusCode) =>
      statusCode == 404 ||
      statusCode == 405 ||
      statusCode == 408 ||
      statusCode == 425 ||
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  bool _isTrustedGoogleUri(Uri uri) {
    if (uri.scheme != 'https') return false;
    return uri.host == 'script.googleusercontent.com' ||
        uri.host == 'script.google.com';
  }

  bool _isAppsScriptExecUri(Uri uri) =>
      uri.host == 'script.google.com' &&
      uri.path.contains('/macros/s/') &&
      uri.path.endsWith('/exec');

  Map<String, dynamic> _decode(http.Response response) {
    var bodyText = response.body;
    if (bodyText.startsWith('\uFEFF')) {
      bodyText = bodyText.substring(1);
    }
    final trimmed = bodyText.trim();
    final contentType = response.headers['content-type'] ?? '';

    if (trimmed.isEmpty) {
      throw _TransientGoogleResponse(
        'empty response body',
        response.statusCode,
      );
    }

    if (contentType.contains('text/html') ||
        trimmed.startsWith('<!DOCTYPE') ||
        trimmed.startsWith('<html')) {
      throw _TransientGoogleResponse(
        'HTML returned instead of JSON',
        response.statusCode,
      );
    }

    try {
      final body = jsonDecode(trimmed);
      if (body is Map<String, dynamic>) return body;
      throw _TransientGoogleResponse(
        'unexpected JSON type',
        response.statusCode,
      );
    } on FormatException {
      throw _TransientGoogleResponse(
        'invalid JSON response',
        response.statusCode,
      );
    }
  }

  String _errorMessage(Map<String, dynamic> data) {
    final message = data['message'];
    if (message is String && message.isNotEmpty) return message;
    return 'تعذر إكمال الطلب.';
  }
}
