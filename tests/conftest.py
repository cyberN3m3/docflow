import os
import tempfile

# Configure BEFORE the app is imported: SQLite DB, temp storage, Celery inline.
_tmp = tempfile.mkdtemp(prefix="docflow-test-")
os.environ["DATABASE_URL"] = f"sqlite:///{_tmp}/test.db"
os.environ["STORAGE_DIR"] = f"{_tmp}/uploads"
os.environ["CELERY_EAGER"] = "true"
os.environ["SECRET_KEY"] = "test-secret"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import gotenberg  # noqa: E402
from app.main import app  # noqa: E402

FAKE_PDF = b"%PDF-1.4\n% fake pdf for tests\n%%EOF"


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture(autouse=True)
def fake_gotenberg(monkeypatch):
    calls = {"convert": [], "merge": []}

    def convert(name, data):
        calls["convert"].append(name)
        return FAKE_PDF

    def merge(files):
        calls["merge"].append([n for n, _ in files])
        return FAKE_PDF

    monkeypatch.setattr(gotenberg, "convert_to_pdf", convert)
    monkeypatch.setattr(gotenberg, "merge_pdfs", merge)
    return calls


_counter = 0


@pytest.fixture
def logged_in(client):
    global _counter
    _counter += 1
    r = client.post("/register", data={"email": f"user{_counter}@example.com", "password": "password123"})
    assert r.status_code == 200 and "/dashboard" in str(r.url)
    return client
