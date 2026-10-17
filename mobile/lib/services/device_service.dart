import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceService {
  static const _storage = FlutterSecureStorage();
  static const _deviceKey = 'installation_device_id';

  Future<String> getOrCreateDeviceId() async {
    final existing = await _storage.read(key: _deviceKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    final id = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await _storage.write(key: _deviceKey, value: id);
    return id;
  }
}
