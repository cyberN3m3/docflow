# DocFlow cost analysis: one server vs AWS

**Short answer:** running DocFlow on AWS around the clock costs about **$82 a month**, compared with **$24** for the single server it replaced. Phase 9 cut the AWS bill by **22%** (from $105). The extra ~$58 a month buys redundancy, managed backups, scaling, a WAF and zero servers to patch. For a demo that runs only when needed, the AWS bill is about **$4.50 a month**.

All figures come from `scripts/cost/estimate.py` (published us-east-1 on-demand prices, October 2026). Re-run it after any infrastructure change.

## 1. Monthly cost, always on

| Component | Before Phase 9 | After Phase 9 |
| --- | ---: | ---: |
| Fargate web (0.25 vCPU, 0.5 GB) | 9.01 | 9.01 |
| Fargate worker + Gotenberg (1 vCPU, 2 GB) | 36.04 | **12.61** (Spot) |
| Application Load Balancer | 17.59 | 17.59 |
| Public IPv4 addresses (ALB × 2, one per task) | 14.60 | 14.60 |
| RDS PostgreSQL db.t4g.micro + 20 GB gp3 | 13.98 | 13.98 |
| AWS WAF (web ACL, 5 rules, 0.5 M requests) | 10.30 | 10.30 |
| Secrets Manager (2 secrets) | 0.80 | 0.80 |
| CloudWatch, S3, SQS, ECR, CloudTrail, flow logs (estimate) | 3.00 | 3.00 |
| CloudFront (always-free 1 TB tier) | 0.00 | 0.00 |
| **Total (USD / month)** | **105.32** | **81.90** |

| Scenario | USD / month |
| --- | ---: |
| Legacy: Lightsail 4 GB VM running all six containers | 24.00 |
| AWS always on, before Phase 9 | 105.32 |
| **AWS always on, after Phase 9** | **81.90** |
| AWS always on, plus Graviton (next step) | 77.57 |
| **AWS demo, up 40 hours a month** (how this project runs) | **4.49** |

Running the environment costs about **$0.11 an hour**.

Assumptions (in the script): light traffic (0.2 load balancer capacity units on average, 0.5 million requests a month), Fargate Spot at a 65% discount (AWS advertises up to 70%), and data transfer within free tiers.

## 2. What the extra $58 a month buys

| Legacy server ($24) | AWS ($82) |
| --- | --- |
| One machine: a crash, reboot or disk failure takes everything down | Load balancer across two Availability Zones; ECS replaces failed tasks automatically |
| Database on the same disk; backups only when someone runs a script | Managed PostgreSQL with automated backups and point-in-time restore |
| Files on local disk | S3: 11 nines of durability, versioning |
| Fixed size: built for the peak, idle the rest of the time | Web scales 1–3 tasks on CPU, worker 1–4 on queue depth |
| Someone patches the OS, Docker and Postgres | No servers to patch |
| No HTTPS, no firewall | HTTPS, WAF, DDoS protection (Shield Standard) |
| SSH and `git pull` deploys | Tested, scanned, zero-downtime deploys with automatic rollback |

**When AWS is the right call:** once an hour of downtime, one lost file or one breach costs more than ~$58 a month, or once traffic varies enough that a fixed server is either too small or wasted. For a hobby project with no customers, the single server is the cheaper and reasonable choice, and saying so is part of giving honest advice.

## 3. Cost decisions made in this project

| Decision | Saving (per month) | Trade-off |
| --- | ---: | --- |
| **No NAT Gateway**: tasks in public subnets, inbound blocked by security groups | ~$66 (2 × $32.85 plus data) | Tasks need public IPs ($3.65 each) |
| **Worker on Fargate Spot** (Phase 9) | $23.43 | AWS can reclaim the task with 2 minutes' warning. Celery finishes or re-queues the job (`acks_late`, `stopTimeout = 120`) |
| **Destroy the environment after every session** | ~$77 at 40 hours/month | About 15 minutes to rebuild; the database doesn't persist between sessions |
| S3 gateway endpoint for file traffic | data transfer | None (free) |
| CloudFront free tier instead of paying for ALB data transfer out | data transfer | None |
| Single-AZ db.t4g.micro (Graviton) | ~$12 vs Multi-AZ | No automatic database failover (see the DR plan) |
| SQS long polling (20 s) | requests | None |
| Lifecycle rules: uploaded originals expire after 7 days, old versions after 30 | storage | Originals can't be re-downloaded after a week |
| Short log retention (7–30 days) | storage | Shorter history for investigations |
| No Container Insights; free service-level ECS metrics instead | ~$10 | Less detailed per-task metrics |

## 4. Next optimisations (not yet done)

| Idea | Estimated saving | Why not yet |
| --- | ---: | --- |
| Graviton (ARM64) Fargate tasks | $4.33 | Needs a multi-architecture image build in CI |
| IPv6 for tasks instead of public IPv4 | up to $7.30 | Every dependency (ECR, Docker Hub for Gotenberg, AWS APIs) must work over IPv6 |
| Compute Savings Plan (1 year, no upfront) | ~20% of Fargate | Only worth it once the environment runs 24/7 |
| Schedule web and worker to 0 tasks at night | ~30% of Fargate | Only for internal tools with office hours |
| Share one ALB across several apps | up to $17.59 | Only one app here |

## 5. Keeping costs visible

- **AWS Budgets** alert (Phase 0) emails before spending passes the limit.
- Every resource is tagged `Project = docflow` (Terraform `default_tags`). With the tag activated as a **cost allocation tag**, Cost Explorer shows the spend for this project alone.
- `scripts/cost/estimate.py` keeps the model next to the code; a change to task sizes or rules updates the numbers.

### Actual spend (from Cost Explorer)

| Period | Actual cost |
| --- | --- |
| Whole project to date | _from Cost Explorer_ |
| Highest-cost service | _from Cost Explorer_ |

## Sources

- [AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/): Linux/x86 $0.0404784 per vCPU-hour, $0.004446 per GB-hour; ARM $0.03237984 and $0.00356004; Spot "up to a 70% discount"
- [Elastic Load Balancing pricing summary (CloudBurn)](https://cloudburn.io/blog/aws-elastic-load-balancing-pricing): ALB $0.0225 per hour, $0.008 per LCU-hour
- [AWS public IPv4 charge (AWS News Blog)](https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights): $0.005 per IP per hour
- [db.t4g.micro pricing (Bytebase)](https://www.bytebase.com/dbcost/rds/instance/db.t4g.micro/) and [Amazon RDS for PostgreSQL pricing](https://aws.amazon.com/rds/postgresql/pricing): about $12 a month ($0.016 per hour)
- [AWS WAF pricing](https://aws.amazon.com/waf/pricing): $5 per web ACL, $1 per rule, $0.60 per million requests, prorated hourly
- [Amazon Lightsail pricing (CloudBurn)](https://cloudburn.io/blog/amazon-lightsail-pricing): 4 GB plan $24 a month, IPv4 included
