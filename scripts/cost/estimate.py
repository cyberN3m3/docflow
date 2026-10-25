"""Monthly cost model: legacy single server vs DocFlow on AWS.

Every price is a published on-demand list price for us-east-1, checked in
October 2026 (sources in docs/cost-analysis.md). Usage figures (traffic,
storage) are assumptions for a small business, labelled as such. Re-run it
after changing anything in infra/ to keep docs/cost-analysis.md honest.

Usage:  python3 scripts/cost/estimate.py [--session-hours 40]
"""
import argparse

HOURS_PER_MONTH = 730

# --- Published prices (USD, us-east-1) ----------------------------------------
PRICE = {
    "fargate_vcpu_hr": 0.0404784,     # Linux/x86
    "fargate_gb_hr": 0.004446,
    "fargate_arm_vcpu_hr": 0.03237984,
    "fargate_arm_gb_hr": 0.00356004,
    "alb_hr": 0.0225,
    "alb_lcu_hr": 0.008,
    "public_ipv4_hr": 0.005,
    "rds_t4g_micro_hr": 0.016,        # PostgreSQL, single-AZ
    "rds_gp3_gb_month": 0.115,
    "secret_month": 0.40,
    "waf_acl_month": 5.00,
    "waf_rule_month": 1.00,
    "waf_million_requests": 0.60,
    "lightsail_4gb_month": 24.00,     # 2 vCPU, 4 GB, 80 GB SSD, 4 TB transfer, IPv4 included
}

# --- Assumptions (small business, light traffic) ---------------------------------
SPOT_DISCOUNT = 0.65       # Fargate Spot is "up to 70%" off; real discounts hover around 65-70%
ALB_AVG_LCU = 0.2          # light traffic uses a fraction of one load balancer capacity unit
REQUESTS_MILLION = 0.5     # requests per month through the WAF
WAF_RULES = 5              # see infra/modules/edge/waf.tf
SMALL_SERVICES = 3.00      # CloudWatch logs/metrics, S3, SQS, ECR, CloudTrail storage, flow logs
DB_STORAGE_GB = 20

# Task sizes (infra/modules/compute/variables.tf)
WEB = {"vcpu": 0.25, "gb": 0.5}
WORKER = {"vcpu": 1.0, "gb": 2.0}
# Public IPv4 addresses: the ALB (one per Availability Zone) + one per task
PUBLIC_IPS = 2 + 1 + 1


def fargate(task, hours, arm=False, spot=False):
    vcpu = PRICE["fargate_arm_vcpu_hr" if arm else "fargate_vcpu_hr"]
    gb = PRICE["fargate_arm_gb_hr" if arm else "fargate_gb_hr"]
    cost = (task["vcpu"] * vcpu + task["gb"] * gb) * hours
    return cost * (1 - SPOT_DISCOUNT) if spot else cost


def aws_lines(hours, spot=False, arm=False):
    """Cost of each component for `hours` of running time in a month."""
    return {
        "Fargate web (0.25 vCPU, 0.5 GB)": fargate(WEB, hours, arm),
        "Fargate worker + Gotenberg (1 vCPU, 2 GB)" + (" on Spot" if spot else ""): fargate(WORKER, hours, arm, spot),
        "Application Load Balancer": (PRICE["alb_hr"] + ALB_AVG_LCU * PRICE["alb_lcu_hr"]) * hours,
        f"Public IPv4 addresses ({PUBLIC_IPS})": PUBLIC_IPS * PRICE["public_ipv4_hr"] * hours,
        "RDS PostgreSQL db.t4g.micro": PRICE["rds_t4g_micro_hr"] * hours,
        f"RDS storage ({DB_STORAGE_GB} GB gp3)": DB_STORAGE_GB * PRICE["rds_gp3_gb_month"] * hours / HOURS_PER_MONTH,
        "Secrets Manager (2 secrets)": 2 * PRICE["secret_month"] * hours / HOURS_PER_MONTH,
        f"AWS WAF (web ACL + {WAF_RULES} rules + requests)": (PRICE["waf_acl_month"] + WAF_RULES * PRICE["waf_rule_month"]) * hours / HOURS_PER_MONTH
        + REQUESTS_MILLION * PRICE["waf_million_requests"] * hours / HOURS_PER_MONTH,
        "CloudWatch, S3, SQS, ECR, CloudTrail, flow logs (estimate)": SMALL_SERVICES * hours / HOURS_PER_MONTH,
        "CloudFront (within the always-free 1 TB tier)": 0.0,
    }


def table(title, lines):
    total = sum(lines.values())
    print(f"\n### {title}\n")
    print("| Component | USD / month |")
    print("| --- | ---: |")
    for name, cost in lines.items():
        print(f"| {name} | {cost:,.2f} |")
    print(f"| **Total** | **{total:,.2f}** |")
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--session-hours", type=float, default=40,
                        help="hours per month the demo environment is up (default 40)")
    args = parser.parse_args()

    legacy = PRICE["lightsail_4gb_month"]
    print("### Legacy: one server\n")
    print("| Component | USD / month |")
    print("| --- | ---: |")
    print(f"| Lightsail 4 GB VM (2 vCPU, 80 GB SSD, IPv4 included) running all six containers | {legacy:,.2f} |")
    print(f"| **Total** | **{legacy:,.2f}** |")

    before = table("AWS, always on, before Phase 9 (worker on regular Fargate)", aws_lines(HOURS_PER_MONTH))
    after = table("AWS, always on, after Phase 9 (worker on Fargate Spot)", aws_lines(HOURS_PER_MONTH, spot=True))
    arm = sum(aws_lines(HOURS_PER_MONTH, spot=True, arm=True).values())
    session = sum(aws_lines(args.session_hours, spot=True).values())

    print("\n### Summary\n")
    print("| Scenario | USD / month |")
    print("| --- | ---: |")
    print(f"| Legacy single server | {legacy:,.2f} |")
    print(f"| AWS always on, before Phase 9 | {before:,.2f} |")
    print(f"| AWS always on, after Phase 9 (Spot worker) | {after:,.2f} |")
    print(f"| AWS always on, Spot + Graviton (ARM) next step | {arm:,.2f} |")
    print(f"| AWS demo, up {args.session_hours:g} hours a month, destroyed otherwise | {session:,.2f} |")
    print(f"\nSpot saves {before - after:,.2f} USD/month ({100 * (before - after) / before:.0f}% of the AWS bill).")
    print(f"Cost per hour of running the AWS environment: {after / HOURS_PER_MONTH:,.3f} USD.")


if __name__ == "__main__":
    main()
