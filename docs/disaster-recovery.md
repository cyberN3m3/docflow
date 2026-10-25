# DocFlow disaster recovery plan

## Targets

| | Target | How it's met |
| --- | --- | --- |
| **RPO** (data we can afford to lose) | 10 minutes | RDS point-in-time recovery: transaction logs are shipped about every 5 minutes (measured worst case 8 min 35 s, below), and daily backups are kept for 7 days. S3 versioning keeps every overwritten or deleted file for 30 days |
| **RTO** (time to be back up) | 1 hour | Each scenario below has a scripted or automatic recovery, and the drills measure it |

## Scenarios

| # | What goes wrong | Recovery | Automatic? | Drill |
| --- | --- | --- | --- | --- |
| 1 | A web or worker task crashes | ECS starts a replacement; the load balancer stops sending traffic to unhealthy tasks | Yes | `task-failure-drill.sh` |
| 2 | A bad release | The deployment circuit breaker rolls back to the last working version; or redeploy a previous image tag (tags are immutable) | Yes | Phase 7 pipeline |
| 3 | An Availability Zone goes down | The ALB spans two AZs, and with 2+ tasks ECS spreads them across both (with 1 task, ECS restarts it in the healthy AZ). The database is single-AZ: restore it in the other AZ (scenario 4). Production: Multi-AZ RDS, with automatic failover in about 1–2 minutes | Partly | `task-failure-drill.sh 2` |
| 4 | The database is corrupted, or data is deleted by mistake | Point-in-time restore to a new instance from just before the incident, verify, then point the app at it (`DB_HOST`) | Scripted | `db-restore-drill.sh` |
| 5 | A user's file is deleted or overwritten | Restore the previous S3 version (remove the delete marker) | Scripted | `s3-recovery-drill.sh` |
| 6 | Poison job / conversion bug | After 3 failures the job moves to the dead-letter queue, so other jobs keep flowing; alarm `jobs-dead-lettered` | Yes | — |
| 7 | The whole region is down | All infrastructure is Terraform: apply in another region (change `region`), restore data from cross-region copies. **Not yet in place:** needs AWS Backup cross-region copy for RDS and S3 replication | No | Rebuild time is measured by every `terraform apply` |
| 8 | AWS account compromised | No long-lived keys exist. Revoke SSO sessions, rotate secrets, review CloudTrail, rebuild from Terraform. Production: backups copied to a separate, locked account | Partly | — |

## Backups

| Data | Backup | Kept | Restore |
| --- | --- | --- | --- |
| Database | RDS automated backups + transaction logs (window 03:00–04:00 UTC) | 7 days | Point-in-time restore to any second, as a new instance |
| Files | S3 versioning | Old versions 30 days | Previous version |
| Infrastructure | Terraform code in Git; state in a versioned S3 bucket | Forever / 90 days | `terraform apply` |
| Container images | ECR, immutable tags | Last 10 | Redeploy the tag |
| Audit trail | CloudTrail | 1 year | — |

**Demo caveat:** this environment is destroyed after every session, which deletes the database and its automated backups (`skip_final_snapshot = true`). That's acceptable here because the drills run within a session. Production would set `deletion_protection = true`, take a final snapshot, and copy backups to another region.

## Drill results

Run in the AWS environment after Phase 10 (`scripts/dr/`; raw output in `dr-reports/`, which is git-ignored).

| Drill | Date | Result | Measured |
| --- | --- | --- | --- |
| Database point-in-time restore | 2026-10-25 | **Passed**: 6 users, 22 jobs and 22 files identical in production and the restored copy | RPO **8 min 35 s**; restore **~13 min** (15:16 → 15:29 UTC); RTO incl. verification **~15 min** |
| Deleted file recovery | 2026-10-25 | **Passed**: recovered byte for byte (same SHA-256) | Recovery **4 s** |
| Web task crash, 1 task | 2026-10-25 | **Passed**: ECS replaced the task; `site-errors` alarm emailed ALARM, then OK | Outage **~28 s** (13 of 120 health checks failed) |
| Web task crash, 2 tasks | 2026-10-25 | **Passed**: the other task kept serving | Outage **none** (0 of 120 failed) |
| Rebuild the environment from code | Every session | `terraform apply` from an empty environment | Typically ~15 minutes (CloudFront is the slowest part) |

**What the numbers say:**
- **Database restore:** of the ~13 minutes, about 4.5 were AWS's automatic backup of the newly restored instance (15:24:46 → 15:29:19, from the RDS event history). The measured RPO was above the original 5-minute goal, because logs ship every ~5 minutes and the measurement fell just before a shipment, so the target is now 10 minutes.
- **Task crash:** one task means about half a minute of errors, even though recovery is automatic. Two tasks means none. That's the case for `min_capacity = 2` in production.
- **One fix came out of the drills:** the verification step first read the task's logs before CloudWatch had received them, and saw nothing. `run-task.sh` now waits for the output (up to 60 s). The data was confirmed afterwards from the same task's logs.

Evidence: [restore drill](evidence/phase10-db-restore-drill.png), [alarm email](evidence/phase10-alarm-email.png), [dashboard](evidence/phase10-dashboard.png).

## Production improvements (not done, for cost)

1. Multi-AZ RDS: automatic database failover (about $14 a month more).
2. AWS Backup plan with a cross-region copy for RDS, and S3 cross-region replication: needed for scenario 7.
3. Two web tasks minimum: no outage when one dies (the drills measured ~28 s of errors with 1 task, none with 2).
4. Backups vaulted in a separate AWS account (AWS Backup vault lock): protects against scenario 8.
