"""Application settings, read from environment variables.

The same Docker image runs in two places, and only these settings differ:

  Legacy (Docker Compose)          AWS (ECS Fargate)
  ------------------------         -------------------------------------
  STORAGE_BACKEND=local            STORAGE_BACKEND=s3, S3_BUCKET=...
  REDIS_URL=redis://...            CELERY_BROKER_URL=sqs://, SQS_QUEUE_URL=...
  DATABASE_URL=postgresql://...    DB_HOST, DB_NAME, DB_USER, DB_PASSWORD
"""
import os

from sqlalchemy.engine import URL


def _env(name: str, default: str | None = None) -> str | None:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


class Settings:
    def __init__(self) -> None:
        self.app_name = "DocFlow"
        self.secret_key = _env("SECRET_KEY", "dev-insecure-change-me")
        self.gotenberg_url = _env("GOTENBERG_URL", "http://localhost:3000").rstrip("/")
        self.max_upload_mb = int(_env("MAX_UPLOAD_MB", "20"))
        self.cookie_secure = _env("COOKIE_SECURE", "false").lower() == "true"
        # --- Guests: try DocFlow without an account ---------------------------
        # GUEST_CONVERSIONS=0 turns guest mode off (an account is required).
        self.guest_conversions = int(_env("GUEST_CONVERSIONS", "10"))
        self.guest_ip_daily = int(_env("GUEST_IP_DAILY", "30"))          # per network, per 24 hours
        self.guest_retention_hours = int(_env("GUEST_RETENTION_HOURS", "24"))
        # How many proxies add themselves to X-Forwarded-For in front of the app:
        # 1 = nginx (legacy); 2 = CloudFront + ALB (AWS). 0 = use the socket address.
        self.trusted_proxy_hops = int(_env("TRUSTED_PROXY_HOPS", "1"))
        # Run Celery tasks inline (tests / quick local dev without a broker).
        self.celery_eager = _env("CELERY_EAGER", "false").lower() == "true"

        # --- File storage ---------------------------------------------------
        self.storage_backend = _env("STORAGE_BACKEND", "local").lower()
        self.storage_dir = _env("STORAGE_DIR", "./data/uploads")
        self.s3_bucket = _env("S3_BUCKET")
        self.aws_region = _env("AWS_REGION", _env("AWS_DEFAULT_REGION", "us-east-1"))
        self.download_url_expiry = int(_env("DOWNLOAD_URL_EXPIRY_SECONDS", "300"))

        # --- Job queue ------------------------------------------------------
        # CELERY_BROKER_URL wins; REDIS_URL keeps the legacy .env working.
        self.redis_url = _env("REDIS_URL", "redis://localhost:6379/0")
        self.celery_broker_url = _env("CELERY_BROKER_URL", self.redis_url)
        self.sqs_queue_url = _env("SQS_QUEUE_URL")

        # --- Database -------------------------------------------------------
        self._database_url = _env("DATABASE_URL")
        self.db_host = _env("DB_HOST")
        self.db_port = int(_env("DB_PORT", "5432"))
        self.db_name = _env("DB_NAME", "docflow")
        self.db_user = _env("DB_USER", "docflow")
        self.db_password = _env("DB_PASSWORD")

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024

    @property
    def uses_sqs(self) -> bool:
        return self.celery_broker_url.startswith("sqs://")

    @property
    def database_url(self) -> str:
        """DATABASE_URL if set; otherwise built from DB_* parts (AWS), else SQLite.

        On AWS the password arrives on its own from Secrets Manager, so the URL
        is assembled here. URL.create escapes special characters in the
        password, and sslmode=require refuses unencrypted connections.
        """
        if self._database_url:
            return self._database_url
        if self.db_host:
            url = URL.create(
                drivername="postgresql+psycopg",
                username=self.db_user,
                password=self.db_password,
                host=self.db_host,
                port=self.db_port,
                database=self.db_name,
                query={"sslmode": "require"},
            )
            return url.render_as_string(hide_password=False)
        return "sqlite:///./docflow.db"

    def validate(self) -> None:
        """Fail fast at start-up with a clear message instead of failing later."""
        if self.storage_backend not in ("local", "s3"):
            raise ValueError(f"STORAGE_BACKEND must be 'local' or 's3', not {self.storage_backend!r}")
        if self.storage_backend == "s3" and not self.s3_bucket:
            raise ValueError("STORAGE_BACKEND=s3 needs S3_BUCKET")
        if self.uses_sqs and not self.sqs_queue_url:
            raise ValueError("An sqs:// broker needs SQS_QUEUE_URL")
        if self.db_host and not self.db_password and not self._database_url:
            raise ValueError("DB_HOST is set but DB_PASSWORD is missing")


settings = Settings()
