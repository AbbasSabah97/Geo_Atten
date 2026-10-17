from app.services import evaluate_geofence, haversine_distance_m


def test_distance_same_point_is_zero():
    assert haversine_distance_m(32.5, 44.4, 32.5, 44.4) == 0


def test_roughly_111m_for_point_001_degree_north():
    distance = haversine_distance_m(32.5, 44.4, 32.501, 44.4)
    assert 105 <= distance <= 117


def test_geofence_accepts_good_location():
    accepted, reason = evaluate_geofence(
        distance_m=18,
        radius_m=50,
        accuracy_m=9,
        max_accuracy_m=35,
        is_mocked=False,
        device_matches=True,
        worksite_enabled=True,
    )
    assert accepted is True
    assert reason is None


def test_geofence_rejects_outside_radius():
    accepted, reason = evaluate_geofence(
        distance_m=80,
        radius_m=50,
        accuracy_m=9,
        max_accuracy_m=35,
        is_mocked=False,
        device_matches=True,
        worksite_enabled=True,
    )
    assert accepted is False
    assert 'خارج النطاق' in reason


def test_geofence_rejects_mock_location():
    accepted, reason = evaluate_geofence(
        distance_m=10,
        radius_m=50,
        accuracy_m=6,
        max_accuracy_m=35,
        is_mocked=True,
        device_matches=True,
        worksite_enabled=True,
    )
    assert accepted is False
    assert 'Mock' in reason


def test_geofence_rejects_poor_accuracy():
    accepted, reason = evaluate_geofence(
        distance_m=10,
        radius_m=50,
        accuracy_m=60,
        max_accuracy_m=35,
        is_mocked=False,
        device_matches=True,
        worksite_enabled=True,
    )
    assert accepted is False
    assert 'دقة الموقع' in reason
