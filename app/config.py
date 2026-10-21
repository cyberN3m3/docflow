"""Application settings, read from environment variables.

Everything configurable lives here so the same image can run on a single VM
(today) and on AWS ECS (after the migration) with only env changes.
"""
import os


def _env(name: str, default: str | None = None) -> str | None:
    return os.environ.get(name, default)


class Settings:
    def __init__(self) -> None:
        self.app_name = "DocFlow"
        self.secret_key = _env("SECRET_KEY", "dev-insecure-change-me")
        self.database_url = _env("DATABASE_URL", "sqlite:///./docflow.db")
        self.redis_url = _env("REDIS_URL", "redis://localhost:6379/0")
        self.gotenberg_url = _env("GOTENBERG_URL", "http://localhost:3000").rstrip("/")
        self.storage_dir = _env("STORAGE_DIR", "./data/uploads")
        self.max_upload_mb = int(_env("MAX_UPLOAD_MB", "20"))
        self.cookie_secure = _env("COOKIE_SECURE", "false").lower() == "true"
        # Run Celery tasks inline (tests / quick local dev without Redis).
        self.celery_eager = _env("CELERY_EAGER", "false").lower() == "true"

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024


settings = Settings()
