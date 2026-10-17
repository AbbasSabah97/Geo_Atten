import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class ApiService {
  static const _storage = FlutterSecureStorage();
  static const _tokenKey = 'access_token';

  Uri _uri(String path) {
    final base = AppConfig.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$path');
  }

  Future<Map<String, dynamic>> login({
    required String employeeCode,
    required String pin,
    required String deviceId,
  }) async {
    final response = await http
        .post(
          _uri('/api/v1/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'employee_code': employeeCode.trim(),
            'pin': pin,
            'device_id': deviceId,
          }),
        )
        .timeout(const Duration(seconds: 15));

    final data = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorMessage(data), response.statusCode);
    }

    final token = data['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw ApiException('الخادم لم يرجع رمز دخول صالحاً.');
    }

    await _storage.write(key: _tokenKey, value: token);
    return data;
  }

  Future<void> logout() => _storage.delete(key: _tokenKey);

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<Map<String, dynamic>> me() async {
    return _authorizedGet('/api/v1/me');
  }

  Future<List<dynamic>> history() async {
    final data = await _authorizedGet('/api/v1/attendance/history');
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
    final token = await readToken();
    if (token == null) throw ApiException('انتهت جلسة الدخول.');

    final response = await http
        .post(
          _uri('/api/v1/attendance/punch'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({
            'event_type': eventType,
            'latitude': latitude,
            'longitude': longitude,
            'accuracy_meters': accuracyMeters,
            'is_mocked': isMocked,
            'device_id': deviceId,
          }),
        )
        .timeout(const Duration(seconds: 20));

    final data = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorMessage(data), response.statusCode);
    }
    return data;
  }

  Future<Map<String, dynamic>> _authorizedGet(String path) async {
    final token = await readToken();
    if (token == null) throw ApiException('غير مسجل الدخول.');

    final response = await http.get(
      _uri(path),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 15));

    final data = _decode(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(_errorMessage(data), response.statusCode);
    }
    return data;
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) return body;
      return {'detail': response.body};
    } catch (_) {
      return {'detail': response.body.isEmpty ? 'خطأ غير معروف من الخادم.' : response.body};
    }
  }

  String _errorMessage(Map<String, dynamic> data) {
    final detail = data['detail'];
    if (detail is String && detail.isNotEmpty) return detail;
    final message = data['message'];
    if (message is String && message.isNotEmpty) return message;
    return 'تعذر إكمال الطلب.';
  }
}
