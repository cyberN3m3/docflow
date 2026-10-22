"""Migration round trip: export from one database, import into a fresh one,
and check nothing was lost. Uses two SQLite databases, so it runs anywhere."""
import json
import uuid

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app import migrate
from app.db import Base, SessionLocal
from app.models import Job, User
from app.storage import LocalStorage


SECOND_EMAIL = f"second-{uuid.uuid4().hex[:8]}@brightwave.test"


@pytest.fixture
def source_data(logged_in):
    """Legacy users with converted files, like the Phase 0 sample data.

    The test database is shared with other tests, so it may already hold
    more users and jobs; the assertions below work from the export itself.
    """
    logged_in.post("/convert", files={"file": ("invoice.docx", b"x")})
    logged_in.post("/convert", files={"file": ("minutes.txt", b"y")})
    logged_in.post("/logout")
    logged_in.post("/register", data={"email": SECOND_EMAIL, "password": "password123"})
    logged_in.post("/convert", files={"file": ("leave.docx", b"z")})
    with SessionLocal() as db:
        return migrate.export_data(db)


def finished_files(data: dict) -> int:
    return sum(1 for j in data["jobs"] if j["status"] == "done" and j["output_key"])


@pytest.fixture
def target(tmp_path):
    engine = create_engine(f"sqlite:///{tmp_path}/target.db")
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine, expire_on_commit=False)


def test_export_is_plain_json(source_data):
    text = json.dumps(source_data)  # would raise if anything isn't serialisable
    assert source_data["format_version"] == migrate.FORMAT_VERSION
    assert SECOND_EMAIL in text
    assert all(u["password_hash"].startswith("$2") for u in source_data["users"])


def test_round_trip_keeps_everything(source_data, target):
    with target() as db:
        result = migrate.import_data(db, source_data)
        assert result == {"users": len(source_data["users"]), "jobs": len(source_data["jobs"])}

    with target() as db:
        assert migrate.export_data(db) == source_data  # identical, field for field


def test_users_can_still_log_in_after_import(source_data, target):
    from app.auth import verify_password

    with target() as db:
        migrate.import_data(db, source_data)
        user = db.query(User).filter_by(email=SECOND_EMAIL).one()
        assert verify_password("password123", user.password_hash)


def test_import_refuses_a_non_empty_database(source_data, target):
    with target() as db:
        migrate.import_data(db, source_data)
    with target() as db, pytest.raises(RuntimeError, match="--replace"):
        migrate.import_data(db, source_data)


def test_replace_overwrites_test_data(source_data, target):
    with target() as db:
        db.add(User(id=999, email="e2e@example.com", password_hash="x"))
        db.commit()
        migrate.import_data(db, source_data, replace=True)
        emails = {u.email for u in db.query(User)}
        assert "e2e@example.com" not in emails
        assert SECOND_EMAIL in emails


def test_failed_import_changes_nothing(source_data, target):
    broken = json.loads(json.dumps(source_data))
    broken["jobs"][0]["kind"] = None  # violates NOT NULL

    with target() as db, pytest.raises(Exception):
        migrate.import_data(db, broken)
    with target() as db:
        assert db.query(User).count() == 0  # rolled back: no half-imported data
        assert db.query(Job).count() == 0


def test_counts_detect_missing_files(source_data, target, tmp_path):
    storage = LocalStorage(str(tmp_path / "files"))
    with target() as db:
        migrate.import_data(db, source_data)
        before = migrate.collect_counts(db, storage)
        assert before["finished_files_expected"] == finished_files(source_data) >= 3
        assert before["finished_files_present"] == 0  # files not copied yet

        for job in db.query(Job).filter_by(status="done"):
            storage.save(job.output_key, b"%PDF")
        after = migrate.collect_counts(db, storage)
        assert after["finished_files_present"] == after["finished_files_expected"]
        assert after["user_emails"] == sorted(u["email"] for u in source_data["users"])


def test_cli_counts_prints_one_comparable_line(capsys):
    migrate.main(["counts"])
    line = capsys.readouterr().out.strip()
    assert line.startswith("COUNTS {")
    json.loads(line.removeprefix("COUNTS "))
