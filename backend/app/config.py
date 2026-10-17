from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = 'Geo Attendance API'
    database_url: str = 'sqlite:///./attendance.db'
    jwt_secret: str = 'CHANGE_ME'
    jwt_expire_minutes: int = 720

    worksite_name: str = 'Main Worksite'
    worksite_latitude: float = 0.0
    worksite_longitude: float = 0.0
    worksite_radius_meters: float = 50.0
    max_location_accuracy_meters: float = 35.0

    bootstrap_employee_code: str = 'EMP001'
    bootstrap_employee_name: str = 'Demo Employee'
    bootstrap_employee_pin: str = 'ChangeMe1234'

    model_config = SettingsConfigDict(env_file='.env', env_file_encoding='utf-8', extra='ignore')


settings = Settings()
