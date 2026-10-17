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

class ApiService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'workspace_session_token';
  static const _deviceKey = 'workspace_bound_device_id';

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
      if (extra != null) ...extra,
    };
    return _post(payload);
  }

  Future<Map<String, dynamic>> _post(Map<String, dynamic> payload) async {
    http.Response response;
    try {
      response = await http
          .post(
            _endpoint,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw ApiException('انتهت مهلة الاتصال بخدمة Google. تحقق من الإنترنت ثم حاول مرة أخرى.');
    } on http.ClientException {
      throw ApiException('تعذر الاتصال بخدمة Google. تحقق من الإنترنت ورابط Apps Script.');
    }

    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw ApiException('تعذر الوصول إلى خدمة الحضور (${response.statusCode}).', response.statusCode);
    }

    final data = _decode(response);
    if (data['ok'] != true) {
      final code = data['code']?.toString();
      final status = code == 'UNAUTHORIZED' ? 401 : null;
      throw ApiException(_errorMessage(data), status, code);
    }
    return data;
  }

  Map<String, dynamic> _decode(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';
    final trimmed = response.body.trimLeft();
    if (contentType.contains('text/html') ||
        trimmed.startsWith('<!DOCTYPE') ||
        trimmed.startsWith('<html')) {
      throw ApiException(
        'الرابط المستخدم لا يرجع JSON من Google Apps Script. تأكد من استخدام رابط النشر المنتهي بـ /exec.',
      );
    }

    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) return body;
      throw const FormatException('Unexpected JSON type');
    } catch (_) {
      throw ApiException('استجابة غير صالحة من خدمة الحضور.');
    }
  }

  String _errorMessage(Map<String, dynamic> data) {
    final message = data['message'];
    if (message is String && message.isNotEmpty) return message;
    return 'تعذر إكمال الطلب.';
  }
}
