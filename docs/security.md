# DocFlow security: threat model, controls and audit results

How DocFlow on AWS is protected, what was checked, what was fixed, and which risks are accepted on purpose (with the reason written next to the code).

## 1. What we protect

| Asset | Where it lives | Why it matters |
| --- | --- | --- |
| Users' documents (uploads and PDFs) | S3 files bucket | Customer data; may be confidential |
| Accounts (emails, bcrypt password hashes) | RDS PostgreSQL, private subnets | Account takeover, privacy |
| Secrets (DB password, `SECRET_KEY`) | Secrets Manager | Whoever has them can read the database or forge logins |
| The AWS account and pipeline | IAM, GitHub Actions OIDC roles | Full control of everything above |

## 2. Threat model (STRIDE)

Data flow: **browser → CloudFront + WAF → ALB → web task → SQS → worker + Gotenberg → S3 / RDS**.

| Threat | Example against DocFlow | Mitigations in place |
| --- | --- | --- |
| **S**poofing | Password guessing on `/login`; forged session cookie | WAF limits `/login` to 100 requests per IP per 5 minutes; bcrypt hashes; session cookie signed with a 64-character `SECRET_KEY` from Secrets Manager, `Secure`, `HttpOnly`, `SameSite=Lax` |
| **T**ampering | Changing the app or infrastructure outside review | Read-only container root filesystems; IMMUTABLE image tags; every change goes through a PR with tests, security scans and a Terraform plan; CloudTrail with log file validation |
| **R**epudiation | "I never changed that security group" | CloudTrail in every region, kept for a year; WAF logs of blocked requests; VPC flow logs |
| **I**nformation disclosure | Reading another user's file; intercepting traffic; a public bucket | Ownership check on every job; downloads are 5-minute presigned links; HTTPS for viewers; TLS required by S3 (bucket policy) and RDS (`rds.force_ssl=1`); S3 public access blocked on every DocFlow bucket; database has no internet route |
| **D**enial of service | Request floods; huge uploads; poison jobs | CloudFront + AWS Shield Standard; WAF 2,000 requests per IP per 5 minutes; 20 MB upload limit; autoscaling (web 1–3, worker 1–4); dead-letter queue after 3 failures |
| **E**levation of privilege | Exploiting the app to reach AWS; a stolen CI credential | Non-root containers; one IAM role per service, scoped to its own bucket and queue; service trust policies limited to this account (confused-deputy protection); no AWS keys anywhere (OIDC + task roles); deploy role usable only from `main`, plan role only from PRs and read-only; WAF managed rules (OWASP-style, Log4j, IP reputation) |

## 3. Controls by layer

| Layer | Control |
| --- | --- |
| Edge | CloudFront (HTTPS, security headers policy), **AWS WAF**: login and per-IP rate limits, AWS IP reputation list, known bad inputs (Log4Shell), common rule set tuned for file uploads |
| Network | ALB accepts only CloudFront's IP ranges **and** a secret header; one security group per tier; database in private subnets with no internet route; **default security group locked**; **VPC flow logs** |
| Compute | Fargate (no servers to patch); non-root user; **read-only root filesystem** (web and worker) with a scratch `/tmp`; secrets injected at start-up, never in the task definition; image scanned on push |
| Data | S3: encryption, versioning, TLS-only, public access blocked, lifecycle; RDS: encryption, private, managed rotating password, **TLS enforced**, **slow-query, schema-change and connection logs** |
| Identity | IAM Identity Center (SSO) with MFA; no IAM users or access keys; GitHub OIDC roles tied to the repo's immutable IDs |
| Account | **CloudTrail** (all regions, log validation), **IAM Access Analyzer**, account-wide S3 public access block (switchable, off here; see section 5), **EBS encryption by default**, **password policy**, AWS Budgets alerts |
| Pipeline | Unit + end-to-end tests; **Gitleaks** (secrets in Git history); **Checkov** (Terraform, Dockerfile, workflows); **pip-audit** (Python CVEs); ECR scan gate blocks CRITICAL vulnerabilities; smoke test checks the WAF blocks a Log4Shell-style request; Dependabot |

Bold items were added in Phase 8.

## 4. Audit results

### Infrastructure as code (Checkov 3.3.30)

| | Before Phase 8 | After Phase 8 |
| --- | --- | --- |
| Passed | 279 | 368 |
| Failed | **51** | **0** |
| Accepted risk (skipped with a written reason) | 0 | 58 |

Of the original 51 findings, **6 were fixed** (WAF, VPC flow logs, default security group, RDS log export, RDS query logging, read-only web container) and **45 were reviewed and accepted** (section 5). The new Phase 8 resources pass the rest, apart from their own documented skips. The CI pipeline now fails on any new finding.

### AWS account (Prowler, CIS benchmark)

Measured with `./scripts/security/prowler-scan.sh before|after`.

| | Before Phase 8 | After Phase 8 |
| --- | --- | --- |
| All checks passing | _to be measured_ | _to be measured_ |
| CIS benchmark passing | _to be measured_ | _to be measured_ |
| Critical / high failures | _to be measured_ | _to be measured_ |

### Container image (Amazon ECR scan)

| | Image `8e10b7b` (Phase 7) | After Phase 8 |
| --- | --- | --- |
| Critical | 0 | _next scan_ |
| High | 3 | _next scan_ |
| Medium / Low | 9 / 3 | _next scan_ |

Fix applied: the Dockerfile now installs the latest Debian security updates and upgrades `pip` at build time, instead of relying on the base image's age.

### Threat detection

GuardDuty (threat detection) and Security Hub (posture score) are enabled through their 30-day free trials. Their findings are reviewed in section 7.

## 5. Accepted risks

Each one is recorded next to the resource as `#checkov:skip=<check>:<reason>`, so an exception can only be added or removed in a reviewed pull request.

| Risk | Why it's accepted here | What production would do |
| --- | --- | --- |
| CloudFront → ALB traffic is HTTP | HTTPS to the origin needs a custom domain and certificate. The ALB accepts only CloudFront IPs plus a secret header | Custom domain + ACM certificate on the ALB, or CloudFront VPC origins with an internal ALB |
| Viewer TLS minimum can't be set | The free `*.cloudfront.net` certificate fixes it | Custom domain with `TLSv1.2_2021` |
| Tasks have public IPs | Avoids a NAT Gateway (about $33/month). Inbound is still blocked by security groups | NAT Gateway or VPC endpoints for ECR, logs and Secrets Manager |
| Single-AZ database, no deletion protection, final snapshot skipped | The environment is destroyed after every session, and Multi-AZ doubles the cost | Multi-AZ, deletion protection, final snapshot, longer backups |
| AWS-managed keys instead of customer-managed KMS keys | Each customer-managed key costs $1/month and adds little for this data | Customer-managed keys where policy or regulation requires them |
| Short log retention (7–30 days); no ALB, CloudFront or S3 access logs | Cost | 1-year retention and access logs into a central log account |
| No anonymous-IP blocking in WAF | It would block VPN users and cloud-hosted clients, including the CI smoke test | Count mode first, then decide using real traffic |
| Gotenberg container is writable | LibreOffice must write its profile and temp files | Same; it has no AWS permissions and no inbound network access |
| `SECRET_KEY` not rotated automatically | Rotating it logs every user out; it is regenerated on each rebuild | Scheduled rotation supporting two active keys |
| Account-wide S3 public access block is off | The AWS account also hosts other projects with public buckets (a static website) and a public Lambda. DocFlow's buckets block public access individually | One AWS account per workload (AWS Organizations), with the account-wide block on everywhere |
| Prowler `ecr_repository_image_no_secrets` | False positive: the match is the text "username/password" inside `/usr/bin/lslogins`, a standard Debian binary | Mute the finding with a documented reason |
| Third-party GitHub Actions pinned to major versions | Easier for a demo; Dependabot keeps them updated | Pin to commit SHAs |

## 6. Image vulnerability policy

- **Critical:** blocks deployment (ECR scan gate in CI).
- **High:** fixed within 7 days, usually by rebuilding (the Dockerfile applies OS security updates) or by merging the Dependabot update.
- **Medium / low:** fixed in the normal Dependabot cycle.

## 7. If something goes wrong (short incident runbook)

1. **Contain:** scale the affected service to 0 (`aws ecs update-service --desired-count 0`), or block the source IP in the WAF.
2. **Credentials:** none are long-lived. Revoke the active SSO sessions, and remove the GitHub OIDC trust if the pipeline is suspected.
3. **Investigate:** CloudTrail (who did what), GuardDuty findings, WAF logs (`aws-waf-logs-docflow-demo`), VPC flow logs, app logs in CloudWatch.
4. **Recover:** redeploy a known-good image tag; restore data as in `docs/disaster-recovery.md`.
5. **Learn:** write a short post-incident note in `docs/` and add a test or rule that would have caught it.
