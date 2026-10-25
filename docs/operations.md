# DocFlow operations: monitoring, alerts and what to do when one fires

## What is watched

Everything is defined in `infra/modules/monitoring/` and created with the rest of the environment. Alerts go to an SNS topic, which emails the address in `TF_VAR_alert_email` (AWS sends a confirmation link first).

**Dashboard:** `terraform output dashboard_url`. One screen, ordered the way a request travels: alarms → requests and errors → response time → WAF → CPU and memory → healthy tasks → job queue → failed conversions → database.

### Alarms (metric thresholds)

| Alarm | Fires when | First things to check |
| --- | --- | --- |
| `site-down` | No healthy web task behind the load balancer for 2 minutes | ECS → `web` service → **Events** tab (crash loop? image pull error?); `/ecs/docflow-demo/web` logs. ECS normally replaces the task by itself within 1–2 minutes |
| `site-errors` | Over 5% of requests fail at CloudFront for 10 minutes | Is it the app (`app-errors` firing too) or the edge? CloudFront → Monitoring |
| `app-errors` | Over 10 server errors (5xx) in 5 minutes | Web logs: search for `Traceback`. A deploy in the last hour? Roll back by redeploying the previous image tag |
| `slow-responses` | p95 latency above 2 s for 10 minutes | Web CPU on the dashboard; database CPU and connections; is autoscaling at its 3-task maximum? |
| `jobs-stuck` | A job has waited over 10 minutes | Worker running? (ECS → `worker`). Worker logs. Queue depth: autoscaling adds workers at about 5 waiting jobs, up to 4 |
| `jobs-dead-lettered` | A job failed 3 times and went to the dead-letter queue | SQS → `docflow-demo-jobs-dlq` → **Send and receive messages** → poll, then read the job ID. That job's row in the database shows the error |
| `jobs-failing` | 5 or more conversions failed in 15 minutes (from worker logs) | Worker logs for `job ... failed:`. Gotenberg memory? A bad file type? |
| `web-cpu-high` | Web CPU above 85% for 15 minutes | Autoscaling is maxed out or not working. Traffic spike (WAF graph)? Raise `max_capacity` or the task size |
| `worker-memory-high` | Worker memory above 90% | LibreOffice on large files. Raise `worker_memory`, or lower Celery concurrency |
| `db-cpu-high` | Database CPU above 80% for 15 minutes | Slow-query log: `/aws/rds/instance/docflow-demo-db/postgresql` (queries over 1 s are logged) |
| `db-storage-low` | Under 2 GB of database storage left | Raise `allocated_storage` (an online change), or turn on storage autoscaling |
| `waf-blocking-spike` | The WAF blocked over 200 requests in 5 minutes | Log group `aws-waf-logs-docflow-demo`: which rule, which IPs? Usually a scanner; nothing to do unless real users are blocked |

### Event alerts (things that happen once)

| Alert | Source |
| --- | --- |
| Deployment failed and was rolled back | ECS deployment circuit breaker |
| Spot worker interrupted | ECS task stopped with `SpotInterruption`. Informational: a replacement starts and in-progress jobs return to the queue |
| GuardDuty finding of high severity (7+) | GuardDuty, when enabled |
| Root user signed in to the console | CloudTrail sign-in events |

## Logs

| Log group | Contents | Kept |
| --- | --- | --- |
| `/ecs/docflow-demo/web` | Web requests and errors | 7 days |
| `/ecs/docflow-demo/worker` | Worker and Gotenberg | 7 days |
| `/aws/rds/instance/docflow-demo-db/postgresql` | Slow queries, schema changes, connections | 7 days |
| `/vpc/docflow-demo/flow-logs` | Every network connection (accepted or rejected) | 7 days |
| `aws-waf-logs-docflow-demo` | Requests the WAF blocked | 30 days |

Useful CloudWatch Logs Insights query for the web logs:

```
fields @timestamp, @message
| filter @message like /ERROR|Traceback/
| sort @timestamp desc
| limit 50
```

## Testing the alerts

1. Apply with `TF_VAR_alert_email` set and confirm the subscription email.
2. Run `./scripts/dr/task-failure-drill.sh 1`. Within about 2 minutes you should get **ALARM: docflow-demo-site-down**, then an **OK** email once ECS replaces the task.
