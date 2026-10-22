"""Tests for the AWS mode: S3 storage, download links, and configuration.

moto fakes S3 in memory, so these run anywhere with no AWS account.
"""
from urllib.parse import urlparse

import boto3
import pytest
from moto import mock_aws

from app import main, worker
from app.config import Settings
from app.storage import S3Storage
from tests.conftest import FAKE_PDF

BUCKET = "docflow-test-files"
REGION = "us-east-1"


@pytest.fixture
def s3(monkeypatch):
    # Fake credentials so nothing can ever reach a real AWS account.
    for name, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_SESSION_TOKEN": "testing",
        "AWS_DEFAULT_REGION": REGION,
    }.items():
        monkeypatch.setenv(name, value)
    with mock_aws():
        boto3.client("s3", region_name=REGION).create_bucket(Bucket=BUCKET)
        yield S3Storage(BUCKET, REGION, url_expiry=300)


# --- S3Storage ---------------------------------------------------------------

def test_s3_save_read_exists_delete(s3):
    s3.save("outputs/1/abc.pdf", FAKE_PDF)
    assert s3.exists("outputs/1/abc.pdf")
    assert s3.read("outputs/1/abc.pdf") == FAKE_PDF

    s3.delete("outputs/1/abc.pdf")
    assert not s3.exists("outputs/1/abc.pdf")


def test_s3_missing_file_does_not_exist(s3):
    assert not s3.exists("outputs/nope.pdf")


def test_s3_download_url_is_signed_and_names_the_file(s3):
    s3.save("outputs/1/abc.pdf", FAKE_PDF)
    url = s3.download_url("outputs/1/abc.pdf", "report.pdf")

    assert BUCKET in url
    assert "X-Amz-Expires=300" in url
    assert "X-Amz-Signature=" in url
    assert "report.pdf" in url  # browser saves it under the right name


# --- The app in S3 mode ------------------------------------------------------

def test_convert_and_download_redirects_to_s3(logged_in, s3, monkeypatch):
    # Swap the app's storage for S3 (web and worker share it, as on AWS).
    monkeypatch.setattr(main, "get_storage", lambda: s3)
    monkeypatch.setattr(worker, "get_storage", lambda: s3)

    logged_in.post("/convert", files={"file": ("invoice.docx", b"fake docx")})
    job_id = logged_in.get("/dashboard").text.split('data-job="')[1].split('"')[0]

    r = logged_in.get(f"/jobs/{job_id}/download", follow_redirects=False)
    assert r.status_code == 302
    location = urlparse(r.headers["location"])
    assert location.scheme == "https"
    assert location.hostname.startswith(f"{BUCKET}.s3.")
    assert location.path.startswith("/outputs/")
    assert "invoice.pdf" in location.query

    # The converted file really is in S3.
    assert s3.read(location.path.lstrip("/")) == FAKE_PDF


def test_local_mode_still_streams_the_file(logged_in):
    logged_in.post("/convert", files={"file": ("notes.txt", b"hello")})
    job_id = logged_in.get("/dashboard").text.split('data-job="')[1].split('"')[0]

    r = logged_in.get(f"/jobs/{job_id}/download", follow_redirects=False)
    assert r.status_code == 200
    assert r.content == FAKE_PDF


# --- Configuration -----------------------------------------------------------

def make_settings(monkeypatch, **env) -> Settings:
    for name in ("DATABASE_URL", "DB_HOST", "DB_PASSWORD", "STORAGE_BACKEND", "S3_BUCKET",
                 "CELERY_BROKER_URL", "SQS_QUEUE_URL", "REDIS_URL"):
        monkeypatch.delenv(name, raising=False)
    for name, value in env.items():
        monkeypatch.setenv(name, value)
    return Settings()


def test_database_url_built_from_parts_escapes_password(monkeypatch):
    s = make_settings(monkeypatch, DB_HOST="db.example.internal", DB_PASSWORD="p@ss:w/rd#1")
    url = s.database_url
    assert url.startswith("postgresql+psycopg://docflow:")
    assert "p%40ss%3Aw%2Frd%231@db.example.internal:5432/docflow" in url
    assert url.endswith("?sslmode=require")


def test_database_url_prefers_explicit_value(monkeypatch):
    s = make_settings(monkeypatch, DATABASE_URL="postgresql+psycopg://a:b@legacy/docflow", DB_HOST="ignored")
    assert s.database_url == "postgresql+psycopg://a:b@legacy/docflow"


def test_broker_defaults_to_redis_for_legacy(monkeypatch):
    s = make_settings(monkeypatch, REDIS_URL="redis://redis:6379/0")
    assert s.celery_broker_url == "redis://redis:6379/0"
    assert not s.uses_sqs


def test_sqs_transport_uses_only_the_predefined_queue():
    opts = worker.sqs_transport_options("us-east-1", "https://sqs.us-east-1.amazonaws.com/123/docflow-demo-jobs")
    assert opts["predefined_queues"] == {
        worker.QUEUE_NAME: {"url": "https://sqs.us-east-1.amazonaws.com/123/docflow-demo-jobs"}
    }
    assert opts["visibility_timeout"] == 900


@pytest.mark.parametrize(
    "env, message",
    [
        ({"STORAGE_BACKEND": "s3"}, "S3_BUCKET"),
        ({"STORAGE_BACKEND": "ftp"}, "STORAGE_BACKEND"),
        ({"CELERY_BROKER_URL": "sqs://"}, "SQS_QUEUE_URL"),
        ({"DB_HOST": "db.example.internal"}, "DB_PASSWORD"),
    ],
)
def test_incomplete_config_fails_fast(monkeypatch, env, message):
    s = make_settings(monkeypatch, **env)
    with pytest.raises(ValueError, match=message):
        s.validate()


def test_aws_config_is_valid(monkeypatch):
    s = make_settings(
        monkeypatch,
        STORAGE_BACKEND="s3",
        S3_BUCKET=BUCKET,
        CELERY_BROKER_URL="sqs://",
        SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/123/docflow-demo-jobs",
        DB_HOST="db.example.internal",
        DB_PASSWORD="secret",
    )
    s.validate()  # no error
    assert s.uses_sqs
