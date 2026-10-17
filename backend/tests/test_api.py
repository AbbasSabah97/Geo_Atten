import os
from pathlib import Path

TEST_DB = Path('test_attendance.db')
TEST_DB.unlink(missing_ok=True)

os.environ['DATABASE_URL'] = 'sqlite:///./test_attendance.db'
os.environ['JWT_SECRET'] = 'test-only-secret-with-sufficient-length'
os.environ['WORKSITE_NAME'] = 'Test Site'
os.environ['WORKSITE_LATITUDE'] = '32.5'
os.environ['WORKSITE_LONGITUDE'] = '44.4'
os.environ['WORKSITE_RADIUS_METERS'] = '50'
os.environ['MAX_LOCATION_ACCURACY_METERS'] = '35'
os.environ['BOOTSTRAP_EMPLOYEE_CODE'] = 'EMP001'
os.environ['BOOTSTRAP_EMPLOYEE_NAME'] = 'Test Employee'
os.environ['BOOTSTRAP_EMPLOYEE_PIN'] = 'Test1234'

from fastapi.testclient import TestClient  # noqa: E402

from app.main import app  # noqa: E402

DEVICE_ID = '0123456789abcdef0123456789abcdef'
OTHER_DEVICE_ID = 'fedcba9876543210fedcba9876543210'


def _login(client: TestClient, device_id: str = DEVICE_ID):
    return client.post('/api/v1/auth/login', json={
        'employee_code': 'EMP001',
        'pin': 'Test1234',
        'device_id': device_id,
    })


def _punch(client: TestClient, token: str, event_type: str, *, lat=32.5, lon=44.4,
           accuracy=8.0, mocked=False, device_id=DEVICE_ID):
    return client.post('/api/v1/attendance/punch', headers={
        'Authorization': f'Bearer {token}',
    }, json={
        'event_type': event_type,
        'latitude': lat,
        'longitude': lon,
        'accuracy_meters': accuracy,
        'is_mocked': mocked,
        'device_id': device_id,
    })


def test_attendance_flow_and_security_controls():
    with TestClient(app) as client:
        login = _login(client)
        assert login.status_code == 200
        token = login.json()['access_token']

        wrong_device = _login(client, OTHER_DEVICE_ID)
        assert wrong_device.status_code == 403

        check_in = _punch(client, token, 'check_in')
        assert check_in.status_code == 200
        assert check_in.json()['accepted'] is True
        assert check_in.json()['distance_meters'] == 0.0

        duplicate = _punch(client, token, 'check_in')
        assert duplicate.status_code == 200
        assert duplicate.json()['accepted'] is False
        assert 'حضور مفتوح' in duplicate.json()['reason']

        check_out = _punch(client, token, 'check_out')
        assert check_out.status_code == 200
        assert check_out.json()['accepted'] is True

        outside = _punch(client, token, 'check_in', lat=32.51)
        assert outside.status_code == 200
        assert outside.json()['accepted'] is False
        assert outside.json()['distance_meters'] > 50

        mocked = _punch(client, token, 'check_in', mocked=True)
        assert mocked.status_code == 200
        assert mocked.json()['accepted'] is False
        assert 'Mock' in mocked.json()['reason']

        poor_accuracy = _punch(client, token, 'check_in', accuracy=100.0)
        assert poor_accuracy.status_code == 200
        assert poor_accuracy.json()['accepted'] is False
        assert 'دقة الموقع' in poor_accuracy.json()['reason']

        history = client.get('/api/v1/attendance/history', headers={
            'Authorization': f'Bearer {token}',
        })
        assert history.status_code == 200
        assert len(history.json()['items']) >= 6
