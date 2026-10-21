import logging
import re
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.middleware.sessions import SessionMiddleware

from .auth import hash_password, password_problem, verify_password
from .config import settings
from .db import db_is_healthy, get_db, init_db
from .gotenberg import CONVERTIBLE_EXTENSIONS
from .models import Job, User
from .storage import get_storage
from .worker import process_job

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("docflow")

BASE_DIR = Path(__file__).parent
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.secret_key,
    same_site="lax",
    https_only=settings.cookie_secure,
    max_age=60 * 60 * 24 * 7,
)
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
templates = Jinja2Templates(directory=BASE_DIR / "templates")


# ---------- helpers ----------

def flash(request: Request, message: str, kind: str = "info") -> None:
    request.session.setdefault("flash", []).append({"message": message, "kind": kind})


def pop_flashes(request: Request) -> list[dict]:
    return request.session.pop("flash", [])


def current_user(request: Request, db: Session) -> User | None:
    user_id = request.session.get("user_id")
    return db.get(User, user_id) if user_id else None


def require_user(request: Request, db: Session = Depends(get_db)) -> User:
    user = current_user(request, db)
    if user is None:
        raise HTTPException(status_code=401, detail="Not logged in")
    return user


def render(request: Request, name: str, **context):
    context.setdefault("user", None)
    context["flashes"] = pop_flashes(request)
    context["app_name"] = settings.app_name
    context["max_upload_mb"] = settings.max_upload_mb
    return templates.TemplateResponse(request, name, context)


def safe_filename(name: str) -> str:
    name = Path(name or "file").name
    name = re.sub(r"[^A-Za-z0-9._ -]", "_", name).strip() or "file"
    return name[:150]


def extension(name: str) -> str:
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


async def read_upload(upload: UploadFile) -> bytes:
    data = await upload.read(settings.max_upload_bytes + 1)
    if len(data) > settings.max_upload_bytes:
        raise ValueError(f"{upload.filename} is larger than {settings.max_upload_mb} MB.")
    if not data:
        raise ValueError(f"{upload.filename} is empty.")
    return data


def enqueue(db: Session, job: Job) -> None:
    try:
        process_job.delay(job.id)
    except Exception as exc:  # broker down: fail visibly rather than leave the job stuck
        log.exception("could not enqueue job %s", job.id)
        job.status = "failed"
        job.error = f"Could not queue job: {exc}"
        db.commit()


def get_own_job(db: Session, user: User, job_id: str) -> Job:
    job = db.get(Job, job_id)
    if job is None or job.user_id != user.id:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


# ---------- health ----------

@app.get("/healthz")
def healthz():
    """Load balancer health check (ALB target group will hit this after migration)."""
    if not db_is_healthy():
        return JSONResponse({"status": "unhealthy", "database": "down"}, status_code=503)
    return {"status": "ok", "database": "up"}


# ---------- auth ----------

@app.get("/")
def index(request: Request, db: Session = Depends(get_db)):
    return RedirectResponse("/dashboard" if current_user(request, db) else "/login", status_code=303)


@app.get("/register")
def register_form(request: Request):
    return render(request, "register.html")


@app.post("/register")
def register(request: Request, email: str = Form(...), password: str = Form(...), db: Session = Depends(get_db)):
    email = email.strip().lower()
    error = None
    if not EMAIL_RE.match(email):
        error = "Enter a valid email address."
    elif problem := password_problem(password):
        error = problem
    elif db.scalar(select(User).where(User.email == email)):
        error = "An account with that email already exists."
    if error:
        flash(request, error, "error")
        return RedirectResponse("/register", status_code=303)

    user = User(email=email, password_hash=hash_password(password))
    db.add(user)
    db.commit()
    request.session.clear()
    request.session["user_id"] = user.id
    flash(request, "Welcome to DocFlow!", "success")
    return RedirectResponse("/dashboard", status_code=303)


@app.get("/login")
def login_form(request: Request):
    return render(request, "login.html")


@app.post("/login")
def login(request: Request, email: str = Form(...), password: str = Form(...), db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.email == email.strip().lower()))
    if user is None or not verify_password(password, user.password_hash):
        flash(request, "Wrong email or password.", "error")
        return RedirectResponse("/login", status_code=303)
    request.session.clear()
    request.session["user_id"] = user.id
    return RedirectResponse("/dashboard", status_code=303)


@app.post("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=303)


# ---------- app ----------

@app.get("/dashboard")
def dashboard(request: Request, db: Session = Depends(get_db)):
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    jobs = db.scalars(
        select(Job).where(Job.user_id == user.id).order_by(Job.created_at.desc()).limit(50)
    ).all()
    return render(
        request, "dashboard.html", user=user, jobs=jobs,
        convertible=", ".join(sorted(CONVERTIBLE_EXTENSIONS)),
    )


@app.post("/convert")
async def convert(request: Request, file: UploadFile = File(...), db: Session = Depends(get_db)):
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)

    name = safe_filename(file.filename)
    if extension(name) not in CONVERTIBLE_EXTENSIONS:
        flash(request, f"Can't convert .{extension(name) or '?'} files.", "error")
        return RedirectResponse("/dashboard", status_code=303)
    try:
        data = await read_upload(file)
    except ValueError as exc:
        flash(request, str(exc), "error")
        return RedirectResponse("/dashboard", status_code=303)

    job = Job(user_id=user.id, kind="convert", input_names=[name], output_name=f"{name.rsplit('.', 1)[0]}.pdf")
    db.add(job)
    db.flush()  # assigns job.id
    key = f"inputs/{user.id}/{job.id}/0_{name}"
    get_storage().save(key, data)
    job.input_keys = [key]
    db.commit()

    enqueue(db, job)
    flash(request, f"Converting {name}…", "success")
    return RedirectResponse("/dashboard", status_code=303)


@app.post("/merge")
async def merge(request: Request, files: list[UploadFile] = File(...), db: Session = Depends(get_db)):
    user = current_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)

    files = [f for f in files if f.filename]
    if len(files) < 2:
        flash(request, "Choose at least two PDFs to merge.", "error")
        return RedirectResponse("/dashboard", status_code=303)
    if len(files) > 20:
        flash(request, "You can merge up to 20 files at once.", "error")
        return RedirectResponse("/dashboard", status_code=303)

    names, blobs = [], []
    for upload in files:
        name = safe_filename(upload.filename)
        if extension(name) != "pdf":
            flash(request, f"{name} is not a PDF.", "error")
            return RedirectResponse("/dashboard", status_code=303)
        try:
            blobs.append(await read_upload(upload))
        except ValueError as exc:
            flash(request, str(exc), "error")
            return RedirectResponse("/dashboard", status_code=303)
        names.append(name)

    job = Job(user_id=user.id, kind="merge", input_names=names, output_name="merged.pdf")
    db.add(job)
    db.flush()
    storage = get_storage()
    keys = []
    for i, (name, data) in enumerate(zip(names, blobs)):
        key = f"inputs/{user.id}/{job.id}/{i}_{name}"
        storage.save(key, data)
        keys.append(key)
    job.input_keys = keys
    db.commit()

    enqueue(db, job)
    flash(request, f"Merging {len(names)} PDFs…", "success")
    return RedirectResponse("/dashboard", status_code=303)


@app.get("/jobs/{job_id}/status")
def job_status(job_id: str, user: User = Depends(require_user), db: Session = Depends(get_db)):
    job = get_own_job(db, user, job_id)
    return {"id": job.id, "status": job.status, "error": job.error}


@app.get("/jobs/{job_id}/download")
def download(job_id: str, user: User = Depends(require_user), db: Session = Depends(get_db)):
    job = get_own_job(db, user, job_id)
    if job.status != "done" or not job.output_key:
        raise HTTPException(status_code=409, detail="Job is not finished")
    # LEGACY: streams the file through the app server. After migration this
    # becomes a redirect to a short-lived S3 presigned URL.
    data = get_storage().read(job.output_key)
    return Response(
        data,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{job.output_name or "output.pdf"}"'},
    )


@app.post("/jobs/{job_id}/delete")
def delete_job(request: Request, job_id: str, user: User = Depends(require_user), db: Session = Depends(get_db)):
    job = get_own_job(db, user, job_id)
    storage = get_storage()
    for key in [*job.input_keys, job.output_key]:
        if key:
            storage.delete(key)
    db.delete(job)
    db.commit()
    flash(request, "Deleted.", "info")
    return RedirectResponse("/dashboard", status_code=303)
