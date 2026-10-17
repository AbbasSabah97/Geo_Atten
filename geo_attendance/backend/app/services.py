from math import atan2, cos, radians, sin, sqrt

EARTH_RADIUS_M = 6_371_000.0


def haversine_distance_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1 = radians(lat1)
    p2 = radians(lat2)
    dphi = radians(lat2 - lat1)
    dlambda = radians(lon2 - lon1)

    a = sin(dphi / 2) ** 2 + cos(p1) * cos(p2) * sin(dlambda / 2) ** 2
    c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return EARTH_RADIUS_M * c


def evaluate_geofence(*, distance_m: float, radius_m: float, accuracy_m: float, max_accuracy_m: float,
                       is_mocked: bool, device_matches: bool, worksite_enabled: bool) -> tuple[bool, str | None]:
    if not worksite_enabled:
        return False, 'موقع العمل غير مفعّل.'
    if is_mocked:
        return False, 'تم اكتشاف موقع وهمي Mock Location.'
    if not device_matches:
        return False, 'هذا الحساب مرتبط بجهاز آخر.'
    if accuracy_m > max_accuracy_m:
        return False, f'دقة الموقع غير كافية ({accuracy_m:.1f} م). الحد الأقصى {max_accuracy_m:.0f} م.'
    if distance_m > radius_m:
        return False, f'أنت خارج النطاق المسموح. المسافة {distance_m:.1f} م والنطاق {radius_m:.0f} م.'
    return True, None
