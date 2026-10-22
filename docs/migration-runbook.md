# DocFlow migration runbook: legacy server → AWS

Moves every user, job and file from the legacy Docker Compose stack to the AWS environment, proves nothing was lost, and records how long the app was unavailable.

| | |
| --- | --- |
| Date | 2026-10-22 |
| Operator | Chieneme |
| Source | Legacy stack (Docker Compose, single server) |
| Target | AWS us-east-1 (ECS Fargate, RDS PostgreSQL, S3), image tag `5ee32be` |
| Downtime (freeze → verified) | **~9 minutes** (19:59:28 → 20:08:27 UTC) |
| Result | **VERIFIED: zero data loss** (5 users, 21 jobs, 21 files) |

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

Times are UTC, taken from Docker and AWS records (container stop time, ECS task start and stop times).

| # | Step | Command / check | Actual time (UTC) | Result |
| --- | --- | --- | --- | --- |
| 1 | AWS environment up, latest image deployed | `terraform apply`; both services `running = 1` | before 19:59 | Image `5ee32be` running |
| 2 | Pre-check: AWS works end to end | `./scripts/e2e.sh "$APP_URL"` | before 19:59 | Passed |
| 3 | Record legacy counts | `docker compose exec -T web python -m app.migrate counts` | before 19:59 | 5 users, 21 jobs |
| 4 | **Freeze legacy (downtime starts)** | `docker compose stop web worker` | **19:59:28** | Legacy stopped |
| 5–8 | Export database and files, upload both to S3 | `app.migrate export`, `tar`, `aws s3 sync`, `aws s3 cp` | 19:59 – 20:05 | Done |
| 9 | Restore into RDS (one-off Fargate task in the VPC) | `run-task.sh python -m app.migrate import --s3-key migration/legacy.json --replace` | 20:05:08 – 20:06:32 | Imported in 1 min 24 s |
| 10 | Count on AWS | `run-task.sh python -m app.migrate counts` | 20:07:52 – **20:08:27** | Done |
| 11 | Compare | `compare.py` | 20:08 | `MIGRATION VERIFIED` |
| 12 | Manual check | Logged in on AWS as a legacy user; old jobs visible; old file downloaded | after 20:08 | Passed |
| 13 | **Cut over (downtime ends)** | CloudFront URL becomes the official address | after manual check | Done |
| 14 | Clean up | Removed `migration/` locally and in S3 | after cut-over | Done |

## Results

| Measure | Legacy | AWS | Result |
| --- | --- | --- | --- |
| Users | 5 | 5 | OK |
| Jobs | 21 | 21 | OK |
| Jobs by status | 21 done | 21 done | OK |
| Finished files present | 21 | 21 | OK |
| **Data lost** | | | **0** |
| **Downtime** (freeze → automated verification) | | | **~9 minutes** |

Evidence: `docs/evidence/phase6-migration-verified.png`

## In a real production migration

- **DNS cut-over:** lower the DNS record's TTL to 60 seconds a day before, then point the domain at CloudFront at step 13, so users switch within a minute.
- **Rehearse:** run steps 5–11 against a copy first, to time them and find surprises before the real window.
- **Large databases:** use AWS Database Migration Service (DMS) to copy continuously while the old system keeps running, which shrinks downtime to minutes.
- **Communicate:** announce the maintenance window to users beforehand.

## Notes / issues found

1. **First deployment returned HTTP 503 (Phase 5).** The ECS service events showed `CannotPullContainerError` for an image tagged `yes`: the value had been typed into Terraform's `image_tag` prompt instead of the real commit hash. Fixed by deriving the tag from Git (`TF_VAR_image_tag=$(git rev-parse --short HEAD)`) so it can't be typed wrong. *Lesson: when a load balancer returns 503, check the ECS service events first.*
2. **Proxy kept routing to a dead container after a rebuild (legacy stack).** nginx resolved the `web` container's address once at start-up, so after `docker compose up --build` replaced the container, every request hung. Fixed by resolving through Docker's DNS every 10 seconds.
3. **A unit test caught insecure download links before deployment (Phase 4).** The first S3 download links were signed with Signature Version 2, which AWS is retiring. The test failed, and the client was switched to SigV4 before any code reached AWS.
4. **The private database shaped the migration design.** RDS has no route to the internet, so instead of opening it up temporarily, the import ran as a one-off Fargate task inside the VPC with the app's own IAM role and secrets. The security model stayed unchanged during the migration.
5. **Clean-up deleted the comparison output before it was recorded here.** Because the legacy stack stayed frozen and AWS unchanged, the counts were re-run and re-verified afterwards (same result). The exact login time for step 12 wasn't noted, so downtime is reported to automated verification. *Next time: copy results into the runbook before cleaning up.*
6. **Most of the downtime was manual work, not machine time.** The import itself took 1 min 24 s. Scripting steps 4–11 into one command would cut downtime to about 3 minutes, which is the next improvement.
