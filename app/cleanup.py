"""Delete guest files and guest accounts once they are older than GUEST_RETENTION_HOURS.

Runs inside the web app every hour (see main.lifespan), so it works the same on
the legacy server and on AWS without a scheduler. Safe to run on several tasks
at once: every step is idempotent.

    python -m app.cleanup      # run once by hand
"""
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from .config import settings
from .db import SessionLocal
from .models import GUEST_EMAIL_DOMAIN, GuestUse, Job, User
from .storage import get_storage

log = logging.getLogger("docflow.cleanup")


def _aware(dt: datetime) -> datetime:
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)  # SQLite returns naive datetimes


def run_cleanup(db, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=settings.guest_retention_hours)
    storage = get_storage()
    guests = db.scalars(select(User).where(User.email.like(f"%@{GUEST_EMAIL_DOMAIN}"))).all()
    removed_jobs = removed_guests = 0

    for guest in guests:
        jobs = db.scalars(select(Job).where(Job.user_id == guest.id)).all()
        for job in jobs:
            if _aware(job.created_at) >= cutoff:
                continue
            for key in [*(job.input_keys or []), job.output_key]:
                if key:
                    try:
                        storage.delete(key)
                    except Exception:  # a missing file must not stop the clean-up
                        log.warning("could not delete %s", key)
            db.delete(job)
            removed_jobs += 1
        db.flush()
        has_jobs = db.scalar(select(Job.id).where(Job.user_id == guest.id).limit(1))
        if not has_jobs and _aware(guest.created_at) < cutoff:
            db.delete(guest)
            removed_guests += 1

    # The per-network counter only needs the last 24 hours; keep two days for margin.
    db.execute(delete(GuestUse).where(GuestUse.created_at < now - timedelta(days=2)))
    db.commit()
    if removed_jobs or removed_guests:
        log.info("cleanup: removed %d guest jobs and %d guests", removed_jobs, removed_guests)
    return {"jobs": removed_jobs, "guests": removed_guests}


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    with SessionLocal() as session:
        print(run_cleanup(session))
