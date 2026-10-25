import httpx

from app import gotenberg
from app.db import SessionLocal
from app.models import Job
from tests.conftest import FAKE_PDF


def latest_job() -> Job:
    with SessionLocal() as db:
        return db.query(Job).order_by(Job.created_at.desc()).first()


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "database": "up"}


def test_dashboard_requires_login(client):
    r = client.get("/dashboard", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"


def test_register_login_logout(client):
    client.post("/register", data={"email": "a@b.co", "password": "password123"})
    client.post("/logout")
    r = client.post("/login", data={"email": "a@b.co", "password": "wrong-pass"})
    assert "Wrong email or password" in r.text
    r = client.post("/login", data={"email": "A@B.co", "password": "password123"})
    assert "Convert to PDF" in r.text


def test_weak_password_rejected(client):
    r = client.post("/register", data={"email": "weak@b.co", "password": "short"})
    assert "at least 8" in r.text


def test_convert_flow(logged_in, fake_gotenberg):
    r = logged_in.post("/convert", files={"file": ("report.docx", b"fake docx bytes")})
    assert r.status_code == 200
    job = latest_job()
    assert job.status == "done"
    assert job.output_name == "report.pdf"
    assert fake_gotenberg["convert"] == ["report.docx"]

    r = logged_in.get(f"/jobs/{job.id}/download")
    assert r.status_code == 200
    assert r.content == FAKE_PDF
    assert r.headers["content-type"] == "application/pdf"


def test_unsupported_extension(logged_in):
    r = logged_in.post("/convert", files={"file": ("virus.exe", b"MZ")})
    assert "Can&#39;t convert .exe" in r.text or "Can't convert .exe" in r.text


def test_merge_requires_two_pdfs(logged_in):
    r = logged_in.post("/merge", files=[("files", ("one.pdf", FAKE_PDF))])
    assert "at least two" in r.text
    r = logged_in.post("/merge", files=[("files", ("a.pdf", FAKE_PDF)), ("files", ("b.docx", b"x"))])
    assert "not a PDF" in r.text


def test_merge_keeps_order(logged_in, fake_gotenberg):
    files = [("files", (n, FAKE_PDF)) for n in ["z.pdf", "a.pdf", "m.pdf"]]
    logged_in.post("/merge", files=files)
    assert fake_gotenberg["merge"] == [["z.pdf", "a.pdf", "m.pdf"]]
    assert latest_job().status == "done"


def test_users_cannot_see_each_others_files(client):
    client.post("/register", data={"email": "owner@b.co", "password": "password123"})
    client.post("/convert", files={"file": ("secret.txt", b"secret")})
    job_id = latest_job().id
    client.post("/logout")

    client.post("/register", data={"email": "intruder@b.co", "password": "password123"})
    assert client.get(f"/jobs/{job_id}/download").status_code == 404
    assert client.get(f"/jobs/{job_id}/status").status_code == 404


def test_conversion_error_marks_job_failed(logged_in, monkeypatch):
    def boom(name, data):
        req = httpx.Request("POST", "http://gotenberg")
        raise httpx.HTTPStatusError("bad", request=req, response=httpx.Response(400, text="corrupt file", request=req))

    monkeypatch.setattr(gotenberg, "convert_to_pdf", boom)
    r = logged_in.post("/convert", files={"file": ("broken.docx", b"junk")})
    job = latest_job()
    assert job.status == "failed"
    assert "corrupt file" in job.error
    assert "corrupt file" in r.text


def test_delete_job(logged_in):
    logged_in.post("/convert", files={"file": ("notes.txt", b"hello")})
    job = latest_job()
    logged_in.post(f"/jobs/{job.id}/delete")
    with SessionLocal() as db:
        assert db.get(Job, job.id) is None


def test_path_traversal_filename_is_sanitised(logged_in):
    logged_in.post("/convert", files={"file": ("../../etc/passwd.txt", b"x")})
    job = latest_job()
    assert ".." not in job.input_keys[0]
    assert job.input_names == ["passwd.txt"]


def test_every_convertible_type_has_a_readable_label():
    from app.gotenberg import CONVERTIBLE_EXTENSIONS
    from app.main import SOURCE_TYPES

    assert CONVERTIBLE_EXTENSIONS <= SOURCE_TYPES.keys()


def test_dashboard_names_the_screen_and_uses_plain_status_words(client):
    client.post("/register", data={"email": "words@example.com", "password": "password123"})
    client.post("/convert", files={"file": ("notes.txt", b"hello", "text/plain")})
    r = client.get("/dashboard")
    assert ">Convert to PDF</h1>" in r.text
    assert ">Your files</h2>" in r.text
    assert "Text to PDF" in r.text
    assert ">Ready<" in r.text
    assert 'data-job="' in r.text
