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


def test_dashboard_requires_login_when_guest_mode_is_off(client, monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "guest_conversions", 0)
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


# ---------- file names from every script ----------

def test_non_latin_names_are_kept(logged_in):
    from urllib.parse import quote

    name = "Ọ̀rọ̀-ìpàdé-ọjọ́-Ajé 2026.docx"
    logged_in.post("/convert", files={"file": (name, b"hello")})
    job = latest_job()
    assert job.input_names == [__import__("unicodedata").normalize("NFC", name)]
    assert job.output_name.endswith("Ajé 2026.pdf")
    assert job.input_keys[0].endswith("/0.docx")  # storage path stays plain ASCII
    assert job.input_keys[0].isascii()

    r = logged_in.get(f"/jobs/{job.id}/download")
    header = r.headers["content-disposition"]
    assert "filename*=UTF-8''" + quote(job.output_name, safe="") in header
    assert 'filename="Oro-ipade-ojo-Aje 2026.pdf"' in header  # readable fallback for old clients


def test_safe_filename_cases():
    from app.filenames import safe_filename

    assert safe_filename("../../etc/passwd.txt") == "passwd.txt"
    assert safe_filename("C:\\Users\\Ngozi\\Desktop\\Kwangilar ƙasa.docx") == "Kwangilar ƙasa.docx"
    assert safe_filename("合同-最终版.pdf") == "合同-最终版.pdf"
    assert safe_filename("bad\x00name\n.txt") == "bad_name_.txt"
    assert safe_filename("  ") == "file"
    long = safe_filename("A" * 300 + ".pptx")
    assert len(long) == 150 and long.endswith(".pptx")


def test_ascii_fallback_never_empty():
    from app.filenames import ascii_fallback

    assert ascii_fallback("合同.pdf") == "document.pdf"
    assert ascii_fallback("Café menu.pdf") == "Cafe menu.pdf"


# ---------- guests ----------

def _guest_convert(client, name="note.txt", ip=None):
    headers = {"X-Forwarded-For": ip} if ip else {}
    return client.post("/convert", files={"file": (name, b"hello")}, headers=headers)


def test_visitor_can_use_the_tool_without_an_account(client):
    from app.models import User

    with SessionLocal() as db:
        users_before = db.query(User).count()
    r = client.get("/")
    assert r.status_code == 200 and ">Convert to PDF</h1>" in r.text
    assert "Sign up free" in r.text and "10 of 10" in r.text
    with SessionLocal() as db:
        assert db.query(User).count() == users_before  # no guest row just for looking


def test_guest_converts_and_downloads(client):
    r = _guest_convert(client, "guest-report.docx")
    assert "9 of 10" in r.text
    job = latest_job()
    assert job.status == "done"
    assert client.get(f"/jobs/{job.id}/download").status_code == 200


def test_guest_limit_and_deleting_does_not_refund(client, monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "guest_conversions", 2)
    _guest_convert(client, "one.txt")
    _guest_convert(client, "two.txt")
    client.post(f"/jobs/{latest_job().id}/delete")
    r = _guest_convert(client, "three.txt")
    assert r.url.path == "/register"
    assert "used your 2 free conversions" in r.text
    assert latest_job().input_names != ["three.txt"]


def test_network_limit_survives_cleared_cookies(client, monkeypatch):
    from app.config import settings

    monkeypatch.setattr(settings, "guest_ip_daily", 2)
    _guest_convert(client, "a.txt", ip="203.0.113.9")
    client.cookies.clear()
    _guest_convert(client, "b.txt", ip="203.0.113.9")
    client.cookies.clear()
    r = _guest_convert(client, "c.txt", ip="203.0.113.9")
    assert r.url.path == "/register" and "used up for today" in r.text
    client.cookies.clear()
    r = _guest_convert(client, "d.txt", ip="198.51.100.4")  # another network is unaffected
    assert r.url.path == "/dashboard"


def test_guest_signup_keeps_files(client):
    _guest_convert(client, "keep-me.txt")
    guest_job = latest_job()
    r = client.post("/register", data={"email": "kept@example.com", "password": "password123"})
    assert "Your files are here" in r.text and "keep-me.pdf" in r.text
    with SessionLocal() as db:
        from app.models import User

        owner = db.get(User, guest_job.user_id)
        assert owner.email == "kept@example.com"


def test_guest_login_brings_files_into_account(client):
    from app.models import User

    client.post("/register", data={"email": "returning@example.com", "password": "password123"})
    client.post("/logout")
    client.cookies.clear()
    _guest_convert(client, "made-as-guest.txt")
    guest_id = latest_job().user_id
    r = client.post("/login", data={"email": "returning@example.com", "password": "password123"})
    assert "made-as-guest.pdf" in r.text
    with SessionLocal() as db:
        assert db.get(User, guest_id) is None
        account = db.query(User).filter_by(email="returning@example.com").one()
        assert latest_job().user_id == account.id


def test_cleanup_removes_only_old_guest_files(client, logged_in):
    from datetime import datetime, timedelta, timezone

    from app.cleanup import run_cleanup
    from app.models import User
    from app.storage import get_storage

    logged_in.post("/convert", files={"file": ("account-file.txt", b"x")})
    account_job = latest_job()
    logged_in.post("/logout")
    logged_in.cookies.clear()
    _guest_convert(logged_in, "old-guest.txt")
    guest_job = latest_job()
    _guest_convert(logged_in, "fresh-guest.txt")
    fresh_job = latest_job()

    old = datetime.now(timezone.utc) - timedelta(hours=30)
    with SessionLocal() as db:
        for job_id in (account_job.id, guest_job.id):
            db.get(Job, job_id).created_at = old
        db.get(User, guest_job.user_id).created_at = old
        db.commit()
        result = run_cleanup(db)

    assert result["jobs"] == 1
    with SessionLocal() as db:
        assert db.get(Job, guest_job.id) is None
        assert db.get(Job, fresh_job.id) is not None      # younger than 24 hours
        assert db.get(Job, account_job.id) is not None    # accounts are never cleaned up
    assert not get_storage().exists(guest_job.input_keys[0])


def test_client_ip_ignores_forged_addresses(monkeypatch):
    from starlette.requests import Request

    from app.config import settings
    from app.main import client_ip

    def req(xff):
        return Request({"type": "http", "headers": [(b"x-forwarded-for", xff.encode())], "client": ("10.0.0.5", 1234)})

    monkeypatch.setattr(settings, "trusted_proxy_hops", 2)  # AWS: CloudFront + ALB
    assert client_ip(req("6.6.6.6, 203.0.113.9, 130.176.0.1")) == "203.0.113.9"
    monkeypatch.setattr(settings, "trusted_proxy_hops", 1)  # legacy: nginx
    assert client_ip(req("6.6.6.6, 203.0.113.9")) == "203.0.113.9"
