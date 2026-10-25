"""Draw the AWS architecture diagram (diagram as code).

Usage:  pip install diagrams  (needs Graphviz: sudo apt-get install -y graphviz)
        python3 scripts/diagram/architecture.py
Writes docs/architecture/aws-architecture.png
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, Fargate
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.devtools import Codebuild
from diagrams.aws.integration import SimpleQueueServiceSqs, SNS
from diagrams.aws.management import Cloudtrail, Cloudwatch
from diagrams.aws.network import CloudFront, ElbApplicationLoadBalancer
from diagrams.aws.security import Guardduty, SecretsManager, WAF
from diagrams.aws.storage import S3
from diagrams.onprem.client import Users
from diagrams.onprem.vcs import Github

OUT = Path(__file__).resolve().parents[2] / "docs" / "architecture" / "aws-architecture"

graph_attr = {"fontsize": "22", "pad": "0.5", "splines": "spline", "nodesep": "0.55", "ranksep": "0.9", "newrank": "true"}
flow = {"color": "#334155", "penwidth": "1.6"}
aux = {"color": "#94a3b8", "style": "dashed"}

with Diagram("DocFlow on AWS (us-east-1)", filename=str(OUT), show=False, direction="LR", graph_attr=graph_attr):
    users = Users("Users")

    with Cluster("Edge"):
        waf = WAF("AWS WAF")
        cdn = CloudFront("CloudFront\nHTTPS")

    with Cluster("VPC: 2 AZs, no NAT Gateway"):
        alb = ElbApplicationLoadBalancer("ALB\nCloudFront only")
        web = Fargate("web\n1-3 tasks")
        worker = Fargate("worker +\nGotenberg\nSpot, 1-4")
        with Cluster("Private subnets"):
            db = RDSPostgresqlInstance("RDS PostgreSQL\n7-day PITR")

    queue = SimpleQueueServiceSqs("SQS jobs\n+ DLQ")
    files = S3("S3 files\nversioned")

    with Cluster("Security and operations"):
        secrets = SecretsManager("Secrets\nManager")
        cw = Cloudwatch("CloudWatch\n12 alarms")
        sns = SNS("Email alerts")
        trail = Cloudtrail("CloudTrail")
        gd = Guardduty("GuardDuty")

    with Cluster("Delivery: GitHub OIDC, no AWS keys"):
        gh = Github("GitHub Actions\ntests + scans")
        ecr = ECR("ECR\nscan gate")

    users >> Edge(label="HTTPS", **flow) >> waf >> Edge(**flow) >> cdn >> Edge(**flow) >> alb >> Edge(**flow) >> web
    web >> Edge(**flow) >> queue >> Edge(**flow) >> worker
    web >> Edge(**flow) >> db
    worker >> Edge(**flow) >> db
    web >> Edge(**flow) >> files
    worker >> Edge(**flow) >> files
    gh >> Edge(**aux) >> ecr >> Edge(**aux) >> web
    secrets >> Edge(**aux) >> web
    cw >> Edge(**aux) >> sns
    trail >> Edge(style="invis") >> gd
