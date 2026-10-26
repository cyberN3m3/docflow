import uuid
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


# Guests are ordinary users with a placeholder address on a reserved domain
# (.invalid can never receive mail), so no table needs a new column.
GUEST_EMAIL_DOMAIN = "guests.invalid"


def is_guest(user: "User | None") -> bool:
    return user is not None and user.email.endswith("@" + GUEST_EMAIL_DOMAIN)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Job(Base):
    """One conversion or merge request. Files themselves live in storage, not the DB."""

    __tablename__ = "jobs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(20))  # "convert" | "merge"
    status: Mapped[str] = mapped_column(String(20), default="queued")  # queued|processing|done|failed
    input_names: Mapped[list] = mapped_column(JSON, default=list)
    input_keys: Mapped[list] = mapped_column(JSON, default=list)
    output_name: Mapped[str | None] = mapped_column(String(255), nullable=True)
    output_key: Mapped[str | None] = mapped_column(String(512), nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class GuestUse(Base):
    """One free conversion by a guest, keyed by a keyed hash of their IP address (never the IP itself).

    Used to cap free conversions per network, so clearing cookies doesn't reset the limit.
    """

    __tablename__ = "guest_uses"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    ip_hash: Mapped[str] = mapped_column(String(64), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
