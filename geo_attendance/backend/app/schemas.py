from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class LoginRequest(BaseModel):
    employee_code: str = Field(min_length=1, max_length=60)
    pin: str = Field(min_length=4, max_length=128)
    device_id: str = Field(min_length=16, max_length=128)


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = 'bearer'
    employee_name: str


class PunchRequest(BaseModel):
    event_type: Literal['check_in', 'check_out']
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_meters: float = Field(gt=0, le=5000)
    is_mocked: bool = False
    device_id: str = Field(min_length=16, max_length=128)


class PunchResponse(BaseModel):
    accepted: bool
    reason: str | None
    distance_meters: float | None
    server_time: datetime


class HistoryItem(BaseModel):
    id: int
    event_type: str
    accepted: bool
    reason: str | None
    distance_meters: float | None
    accuracy_meters: float
    created_at: datetime


class HistoryResponse(BaseModel):
    items: list[HistoryItem]
