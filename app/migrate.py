"""Migration tool: move users and jobs from the legacy server to AWS.

Runs inside the same Docker image as the app, so it uses the app's own
database settings and storage, with nothing extra to configure:

  export   On the legacy server: print every user and job as JSON.
  import   On AWS (one-off ECS task): load that JSON from S3 into RDS.
  counts   Anywhere: print what's there, so legacy and AWS can be compared.

Files are moved separately with `aws s3 sync`; their storage keys stay the
same, so every job still finds its files after the move.

Logs go to stderr; only the data goes to stdout.
"""
import argparse
import json
import logging
import sys
from collections import Counter
from datetime import datetime

from sqlalchemy import delete, func, select, text
from sqlalchemy.orm import Session

from .db import SessionLocal, init_db
from .models import GUEST_EMAIL_DOMAIN, Job, User
from .storage import get_storage

log = logging.getLogger("docflow.migrate")

FORMAT_VERSION = 1
USER_FIELDS = ["id", "email", "password_hash", "created_at"]
JOB_FIELDS = [
    "id", "user_id", "kind", "status", "input_names", "input_keys",
    "output_name", "output_key", "error", "created_at", "finished_at",
]


def _to_json(value):
    return value.isoformat() if isinstance(value, datetime) else value


def _from_json(field: str, value):
    if value is not None and field in ("created_at", "finished_at"):
        return datetime.fromisoformat(value)
    return value


# --- export ------------------------------------------------------------------

def _accounts(db: Session):
    """Real accounts only: guests are temporary (deleted within a day) and are not migrated."""
    users = db.scalars(select(User).where(User.email.not_like(f"%@{GUEST_EMAIL_DOMAIN}")).order_by(User.id)).all()
    ids = {u.id for u in users}
    jobs = [j for j in db.scalars(select(Job).order_by(Job.created_at)).all() if j.user_id in ids]
    return users, jobs


def export_data(db: Session) -> dict:
    users, jobs = _accounts(db)
    return {
        "format_version": FORMAT_VERSION,
        "users": [{f: _to_json(getattr(u, f)) for f in USER_FIELDS} for u in users],
        "jobs": [{f: _to_json(getattr(j, f)) for f in JOB_FIELDS} for j in jobs],
    }


# --- import ------------------------------------------------------------------

def import_data(db: Session, data: dict, replace: bool = False) -> dict:
    """Load exported users and jobs. All or nothing: any error rolls back everything."""
    if data.get("format_version") != FORMAT_VERSION:
        raise ValueError(f"Unsupported export format: {data.get('format_version')!r}")

    existing = db.scalar(select(func.count()).select_from(User))
    if existing and not replace:
        raise RuntimeError(
            f"The target database already has {existing} user(s). "
            "Use --replace to delete them first (only on a fresh environment)."
        )

    try:
        if replace:
            db.execute(delete(Job))
            db.execute(delete(User))

        for row in data["users"]:
            db.add(User(**{f: _from_json(f, row[f]) for f in USER_FIELDS}))
        db.flush()  # users must exist before the jobs that point at them

        for row in data["jobs"]:
            db.add(Job(**{f: _from_json(f, row[f]) for f in JOB_FIELDS}))
        db.flush()

        # Users were inserted with their original IDs, so move Postgres's
        # ID counter past them; otherwise the next sign-up would clash.
        if db.get_bind().dialect.name == "postgresql":
            db.execute(text(
                "SELECT setval(pg_get_serial_sequence('users', 'id'), "
                "COALESCE((SELECT MAX(id) FROM users), 1), "
                "(SELECT COUNT(*) > 0 FROM users))"
            ))

        db.commit()
    except Exception:
        db.rollback()
        raise

    return {"users": len(data["users"]), "jobs": len(data["jobs"])}


# --- counts ------------------------------------------------------------------

def collect_counts(db: Session, storage) -> dict:
    """What a migration must preserve, in a form that's easy to compare."""
    users, jobs = _accounts(db)
    done = [j for j in jobs if j.status == "done" and j.output_key]
    return {
        "users": len(users),
        "user_emails": sorted(u.email for u in users),
        "jobs": len(jobs),
        "jobs_by_status": dict(sorted(Counter(j.status for j in jobs).items())),
        "finished_files_expected": len(done),
        "finished_files_present": sum(1 for j in done if storage.exists(j.output_key)),
    }


# --- command line ------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(prog="python -m app.migrate", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("export", help="print all users and jobs as JSON")
    imp = sub.add_parser("import", help="load an export into this environment's database")
    imp.add_argument("--s3-key", help="read the export from this key in the files bucket")
    imp.add_argument("--file", help="read the export from a local file")
    imp.add_argument("--replace", action="store_true",
                     help="delete existing users and jobs first (fresh environments only)")
    sub.add_parser("counts", help="print users, jobs and file counts for comparison")
    args = parser.parse_args(argv)

    init_db()
    with SessionLocal() as db:
        if args.command == "export":
            data = export_data(db)
            json.dump(data, sys.stdout, indent=1)
            sys.stdout.write("\n")
            log.info("exported %d users and %d jobs", len(data["users"]), len(data["jobs"]))

        elif args.command == "import":
            if bool(args.s3_key) == bool(args.file):
                parser.error("give exactly one of --s3-key or --file")
            raw = get_storage().read(args.s3_key) if args.s3_key else open(args.file, "rb").read()
            result = import_data(db, json.loads(raw), replace=args.replace)
            log.info("imported %d users and %d jobs", result["users"], result["jobs"])
            print("IMPORTED " + json.dumps(result))

        elif args.command == "counts":
            print("COUNTS " + json.dumps(collect_counts(db, get_storage()), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
