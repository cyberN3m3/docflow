"""Celery worker: picks jobs off the queue and runs the conversion.

Start with:  celery -A app.worker.celery_app worker --loglevel=info
"""
import logging

import httpx
from celery import Celery

from . import gotenberg
from .config import settings
from .db import SessionLocal
from .models import Job, utcnow
from .storage import get_storage

log = logging.getLogger(__name__)

QUEUE_NAME = "docflow-jobs"

celery_app = Celery("docflow", broker=settings.celery_broker_url)
celery_app.conf.update(
    task_always_eager=settings.celery_eager,
    task_default_queue=QUEUE_NAME,
    task_acks_late=True,           # don't lose a job if the worker dies mid-conversion
    worker_prefetch_multiplier=1,  # conversions are heavy; take one at a time
    task_ignore_result=True,       # status lives in Postgres, not the result backend
    broker_connection_retry_on_startup=True,
)

def sqs_transport_options(region: str, queue_url: str) -> dict:
    """Point Celery at the queue Terraform created.

    "Predefined" means Celery never tries to create or list queues, so the
    worker's IAM role only needs permission on this one queue (least privilege).
    """
    return {
        "region": region,
        "predefined_queues": {QUEUE_NAME: {"url": queue_url}},
        "visibility_timeout": 900,  # matches the queue's setting in Terraform
        "wait_time_seconds": 20,    # long polling: fewer requests, lower bill
    }


if settings.uses_sqs:
    celery_app.conf.broker_transport_options = sqs_transport_options(
        settings.aws_region, settings.sqs_queue_url
    )


def _fail(db, job: Job, message: str) -> None:
    job.status = "failed"
    job.error = message[:1000]
    job.finished_at = utcnow()
    db.commit()
    log.warning("job %s failed: %s", job.id, message)


@celery_app.task(bind=True, max_retries=3, name="docflow.process_job")
def process_job(self, job_id: str) -> None:
    db = SessionLocal()
    try:
        job = db.get(Job, job_id)
        if job is None:
            log.error("job %s not found", job_id)
            return

        job.status = "processing"
        db.commit()
        storage = get_storage()

        try:
            inputs = [(name, storage.read(key)) for name, key in zip(job.input_names, job.input_keys)]
            if job.kind == "convert":
                pdf = gotenberg.convert_to_pdf(*inputs[0])
            elif job.kind == "merge":
                pdf = gotenberg.merge_pdfs(inputs)
            else:
                return _fail(db, job, f"Unknown job kind: {job.kind}")
        except httpx.TransportError as exc:
            # Gotenberg unreachable / timed out: worth retrying with backoff.
            if self.request.retries < self.max_retries:
                job.status = "queued"
                db.commit()
                raise self.retry(exc=exc, countdown=5 * 2 ** self.request.retries)
            return _fail(db, job, "Conversion service unavailable. Please try again later.")
        except httpx.HTTPStatusError as exc:
            return _fail(db, job, f"Conversion failed ({exc.response.status_code}): {exc.response.text[:300]}")
        except Exception as exc:  # noqa: BLE001
            log.exception("unexpected error in job %s", job_id)
            return _fail(db, job, f"Unexpected error: {exc}")

        output_key = f"outputs/{job.user_id}/{job.id}.pdf"
        storage.save(output_key, pdf)
        job.output_key = output_key
        job.status = "done"
        job.finished_at = utcnow()
        db.commit()
        log.info("job %s done (%d bytes)", job.id, len(pdf))
    finally:
        db.close()
