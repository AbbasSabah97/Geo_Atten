import 'package:geolocator/geolocator.dart';

class LocationCheckResult {
  final Position position;
  final LocationAccuracyStatus accuracyStatus;

  const LocationCheckResult({
    required this.position,
    required this.accuracyStatus,
  });
}

class LocationService {
  Future<LocationCheckResult> getVerifiedPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('خدمة الموقع متوقفة. يرجى تشغيل GPS ثم المحاولة مرة أخرى.');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('تم رفض إذن الموقع. لا يمكن تسجيل الحضور بدون الموقع.');
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception('إذن الموقع مرفوض دائماً. فعّله من إعدادات التطبيق.');
    }

    final accuracyStatus = await Geolocator.getLocationAccuracy();
    if (accuracyStatus == LocationAccuracyStatus.reduced) {
      throw Exception('يجب تفعيل الموقع الدقيق Precise Location لتسجيل الحضور.');
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: Duration(seconds: 20),
      ),
    );

    if (position.isMocked) {
      throw Exception('تم اكتشاف موقع وهمي Mock Location. تم رفض العملية.');
    }

    return LocationCheckResult(
      position: position,
      accuracyStatus: accuracyStatus,
    );
  }
}
