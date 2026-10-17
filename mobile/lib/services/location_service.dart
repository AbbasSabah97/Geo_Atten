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

    Position? best;
    for (var attempt = 0; attempt < 3; attempt++) {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: attempt == 0 ? 18 : 10),
        ),
      );

      if (position.isMocked) {
        throw Exception('تم اكتشاف موقع وهمي Mock Location. تم رفض العملية.');
      }

      if (best == null || position.accuracy < best.accuracy) {
        best = position;
      }

      if (best.accuracy <= 15) break;
    }

    if (best == null) {
      throw Exception('تعذر الحصول على الموقع. حاول مرة أخرى في مكان مفتوح.');
    }

    return LocationCheckResult(
      position: best,
      accuracyStatus: accuracyStatus,
    );
  }
}
