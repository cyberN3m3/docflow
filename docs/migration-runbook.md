# DocFlow migration runbook: legacy server → AWS

Moves every user, job and file from the legacy Docker Compose stack to the AWS environment, proves nothing was lost, and records how long the app was unavailable.

Fill in the **Actual time** column as you go. The times are the evidence.

| | |
| --- | --- |
| Date | _YYYY-MM-DD_ |
| Operator | _your name_ |
| Source | Legacy stack (Docker Compose, single server) |
| Target | AWS us-east-1 (ECS Fargate, RDS PostgreSQL, S3), image tag `_____` |
| Downtime (freeze → cut-over) | _fill in at the end_ |
| Result | _VERIFIED / ROLLED BACK_ |

## How it works

- **Database:** `python -m app.migrate export` writes every user and job to JSON. That file goes to S3, and a one-off Fargate task inside the VPC loads it into the private RDS database with `python -m app.migrate import`. The import is all-or-nothing, and user IDs and password hashes are kept, so everyone keeps their login.
- **Files:** copied with `aws s3 sync`. Storage keys (`inputs/…`, `outputs/…`) are identical in both environments, so every job still finds its files.
- **Proof:** `python -m app.migrate counts` runs on both sides, and `scripts/migrate/compare.py` checks users, jobs per status and every finished file.

Working files go in `migration/`, which is git-ignored because it contains real user data.

## Rollback plan (decided before starting)

If any check fails before cut-over:
1. `docker compose start web worker`: the legacy stack is back. Its data was never modified.
2. Fix the problem, then repeat from step 4. The import's `--replace` overwrites the partial attempt.

After cut-over, the legacy stack stays stopped but intact until the AWS version has run cleanly.

## Steps

| # | Step | Command / check | Actual time (UTC) | Result |
| --- | --- | --- | --- | --- |
| 1 | AWS environment up, latest image deployed | `terraform apply`; both services `running = 1` | | |
| 2 | Pre-check: AWS works end to end | `./scripts/e2e.sh "$APP_URL"` | | |
| 3 | Record legacy counts | `docker compose exec -T web python -m app.migrate counts > migration/legacy-counts.txt` | | |
| 4 | **Freeze legacy (downtime starts)** | `docker compose stop web worker` | | |
| 5 | Export database | `docker compose run --rm --no-deps -T web python -m app.migrate export > migration/legacy.json` | | |
| 6 | Export files | `docker compose run --rm --no-deps -T web tar -czf - -C /data uploads > migration/uploads.tgz` | | |
| 7 | Upload files to S3 | `aws s3 sync migration/uploads/ s3://$BUCKET/` | | |
| 8 | Upload database export | `aws s3 cp migration/legacy.json s3://$BUCKET/migration/legacy.json` | | |
| 9 | Restore into RDS | `./scripts/migrate/run-task.sh python -m app.migrate import --s3-key migration/legacy.json --replace` | | |
| 10 | Count on AWS | `./scripts/migrate/run-task.sh python -m app.migrate counts > migration/aws-counts.txt` | | |
| 11 | Compare | `python3 scripts/migrate/compare.py migration/legacy-counts.txt migration/aws-counts.txt` → `MIGRATION VERIFIED` | | |
| 12 | Manual check | Log in on AWS as a legacy user; see their history; download an old file | | |
| 13 | **Cut over (downtime ends)** | The CloudFront URL becomes the official address | | |
| 14 | Clean up | `aws s3 rm s3://$BUCKET/migration/ --recursive`; delete local `migration/` | | |

## Results

| Measure | Value |
| --- | --- |
| Users migrated | |
| Jobs migrated | |
| Files migrated | |
| Data lost | |
| Downtime (step 4 → step 13) | |

## In a real production migration

- **DNS cut-over:** lower the DNS record's TTL to 60 seconds a day before, then point the domain at CloudFront at step 13, so users switch within a minute.
- **Rehearse:** run steps 5–11 against a copy first, to time them and find surprises before the real window.
- **Large databases:** use AWS Database Migration Service (DMS) to copy continuously while the old system keeps running, which shrinks downtime to minutes.
- **Communicate:** announce the maintenance window to users beforehand.

## Notes / issues found

_Anything that went wrong and how you fixed it. Hiring managers read this part._
