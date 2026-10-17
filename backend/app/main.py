from datetime import datetime, timezone

import jwt
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import Base, SessionLocal, engine, get_db
from .models import AttendanceEvent, Employee, Worksite
from .schemas import HistoryItem, HistoryResponse, LoginRequest, LoginResponse, PunchRequest, PunchResponse
from .security import create_access_token, decode_access_token, hash_pin, verify_pin
from .services import evaluate_geofence, haversine_distance_m

app = FastAPI(title=settings.app_name, version='0.1.0')
bearer = HTTPBearer(auto_error=False)


def bootstrap_database() -> None:
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        worksite = db.scalar(select(Worksite).limit(1))
        site_configured = not (settings.worksite_latitude == 0.0 and settings.worksite_longitude == 0.0)
        if worksite is None:
            worksite = Worksite(
                name=settings.worksite_name,
                latitude=settings.worksite_latitude,
                longitude=settings.worksite_longitude,
                radius_meters=settings.worksite_radius_meters,
                enabled=site_configured,
            )
            db.add(worksite)
            db.flush()
        else:
            # For the MVP, environment configuration is the source of truth for the single worksite.
            worksite.name = settings.worksite_name
            worksite.latitude = settings.worksite_latitude
            worksite.longitude = settings.worksite_longitude
            worksite.radius_meters = settings.worksite_radius_meters
            worksite.enabled = site_configured

        employee = db.scalar(select(Employee).where(Employee.employee_code == settings.bootstrap_employee_code))
        if employee is None:
            db.add(Employee(
                employee_code=settings.bootstrap_employee_code,
                name=settings.bootstrap_employee_name,
                pin_hash=hash_pin(settings.bootstrap_employee_pin),
                worksite_id=worksite.id,
                active=True,
            ))
        db.commit()
    finally:
        db.close()


@app.on_event('startup')
def on_startup() -> None:
    bootstrap_database()


def current_employee(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
) -> Employee:
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail='غير مصرح.')
    try:
        employee_id = decode_access_token(credentials.credentials)
    except (jwt.PyJWTError, ValueError, KeyError):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail='رمز الدخول غير صالح أو منتهي.')

    employee = db.get(Employee, employee_id)
    if employee is None or not employee.active:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail='حساب الموظف غير فعال.')
    return employee


@app.get('/health')
def health():
    return {'status': 'ok', 'service': settings.app_name}


@app.post('/api/v1/auth/login', response_model=LoginResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    employee = db.scalar(select(Employee).where(Employee.employee_code == payload.employee_code.strip()))
    if employee is None or not employee.active or not verify_pin(payload.pin, employee.pin_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail='رمز الموظف أو الرقم السري غير صحيح.')

    if employee.bound_device_id is None:
        employee.bound_device_id = payload.device_id
        db.commit()
    elif employee.bound_device_id != payload.device_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail='هذا الحساب مرتبط بجهاز آخر.')

    return LoginResponse(
        access_token=create_access_token(employee.id),
        employee_name=employee.name,
    )


@app.get('/api/v1/me')
def me(employee: Employee = Depends(current_employee)):
    return {
        'id': employee.id,
        'employee_code': employee.employee_code,
        'name': employee.name,
        'worksite_name': employee.worksite.name,
        'worksite_radius_meters': employee.worksite.radius_meters,
    }


@app.post('/api/v1/attendance/punch', response_model=PunchResponse)
def punch(
    payload: PunchRequest,
    employee: Employee = Depends(current_employee),
    db: Session = Depends(get_db),
):
    worksite = employee.worksite
    distance = haversine_distance_m(
        payload.latitude,
        payload.longitude,
        worksite.latitude,
        worksite.longitude,
    )

    accepted, reason = evaluate_geofence(
        distance_m=distance,
        radius_m=worksite.radius_meters,
        accuracy_m=payload.accuracy_meters,
        max_accuracy_m=settings.max_location_accuracy_meters,
        is_mocked=payload.is_mocked,
        device_matches=employee.bound_device_id == payload.device_id,
        worksite_enabled=worksite.enabled,
    )

    if accepted:
        last_accepted = db.scalar(
            select(AttendanceEvent)
            .where(AttendanceEvent.employee_id == employee.id, AttendanceEvent.accepted.is_(True))
            .order_by(AttendanceEvent.created_at.desc())
            .limit(1)
        )
        if payload.event_type == 'check_in' and last_accepted is not None and last_accepted.event_type == 'check_in':
            accepted, reason = False, 'لديك حضور مفتوح بالفعل. سجّل الانصراف أولاً.'
        elif payload.event_type == 'check_out' and (last_accepted is None or last_accepted.event_type != 'check_in'):
            accepted, reason = False, 'لا يوجد حضور مفتوح لتسجيل الانصراف.'

    now = datetime.now(timezone.utc)
    event = AttendanceEvent(
        employee_id=employee.id,
        event_type=payload.event_type,
        latitude=payload.latitude,
        longitude=payload.longitude,
        accuracy_meters=payload.accuracy_meters,
        is_mocked=payload.is_mocked,
        device_id=payload.device_id,
        distance_meters=distance,
        accepted=accepted,
        reason=reason,
        created_at=now,
    )
    db.add(event)
    db.commit()

    if not accepted:
        # 200 is intentional: the request was processed and recorded, but attendance was denied.
        return PunchResponse(accepted=False, reason=reason, distance_meters=round(distance, 2), server_time=now)

    return PunchResponse(accepted=True, reason=None, distance_meters=round(distance, 2), server_time=now)


@app.get('/api/v1/attendance/history', response_model=HistoryResponse)
def history(
    employee: Employee = Depends(current_employee),
    db: Session = Depends(get_db),
):
    events = db.scalars(
        select(AttendanceEvent)
        .where(AttendanceEvent.employee_id == employee.id)
        .order_by(AttendanceEvent.created_at.desc())
        .limit(50)
    ).all()

    return HistoryResponse(items=[
        HistoryItem(
            id=e.id,
            event_type=e.event_type,
            accepted=e.accepted,
            reason=e.reason,
            distance_meters=e.distance_meters,
            accuracy_meters=e.accuracy_meters,
            created_at=e.created_at,
        )
        for e in events
    ])
