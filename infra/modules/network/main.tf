# The private network for DocFlow: public subnets for the load balancer and
# app containers, private subnets for the database, and no NAT Gateway.

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Only the first two zones are used (count = az_count), so a new zone appearing changes nothing.
  state = "available"
}

data "aws_region" "current" {}

# CloudFront's published IP ranges, maintained by AWS. Used so the load
# balancer only accepts traffic that comes through CloudFront.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# The estate's main gate to the internet.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

# --- Subnets -----------------------------------------------------------------
# Public:  10.0.0.0/24, 10.0.1.0/24   (one per Availability Zone)
# Private: 10.0.10.0/24, 10.0.11.0/24

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Nothing gets a public IP by default; ECS asks for one explicitly.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${var.name}-private-${count.index + 1}" }
}

# --- Routing -----------------------------------------------------------------

# Public subnets: traffic for the internet goes through the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private subnets: deliberately NO route to the internet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Free private road to S3, so file traffic never crosses the public internet.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}

# --- Security groups: one "bouncer" per layer --------------------------------

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:False positive: attached in the edge, compute and database modules, which Checkov can't follow across modules.
  name        = "${var.name}-alb"
  description = "Load balancer: accepts traffic from CloudFront only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-alb" }
}

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:False positive: attached in the edge, compute and database modules, which Checkov can't follow across modules.
  name        = "${var.name}-app"
  description = "Web app: accepts traffic from the load balancer only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-app" }
}

resource "aws_security_group" "worker" {
  #checkov:skip=CKV2_AWS_5:False positive: attached in the edge, compute and database modules, which Checkov can't follow across modules.
  name        = "${var.name}-worker"
  description = "Worker: no inbound traffic at all"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-worker" }
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:False positive: attached in the edge, compute and database modules, which Checkov can't follow across modules.
  name        = "${var.name}-db"
  description = "Database: accepts Postgres from the app and worker only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-db" }
}

# Load balancer: in from CloudFront on port 80, out to the app on port 8000.
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  #checkov:skip=CKV_AWS_260:False positive: the source is CloudFront's managed prefix list, not 0.0.0.0/0.
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the web app"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.app.id
}

# Web app: in from the load balancer only. Out to anywhere (AWS APIs, the
# database, pulling images); there is no NAT Gateway to restrict it further.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the load balancer"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_out" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound to AWS services and the database"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Worker: no inbound rules at all. Out to anywhere (SQS, S3, the database).
resource "aws_vpc_security_group_egress_rule" "worker_out" {
  security_group_id = aws_security_group.worker.id
  description       = "Outbound to AWS services and the database"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Database: Postgres from the app and worker only. No outbound rules needed.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the web app"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_worker" {
  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the worker"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.worker.id
}

# --- Default security group: lock it ------------------------------------------
# Every VPC comes with a "default" security group that lets its members talk
# to each other freely. Nothing uses it, so Terraform takes it over and removes
# all its rules, so nothing can be accidentally launched into it with open access.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-default-locked" }
}

# --- VPC flow logs ---------------------------------------------------------------
# A record of every network connection in the VPC (who, where, which port,
# accepted or rejected). Used to investigate incidents, and GuardDuty can use
# the same data. Kept for 7 days.

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days

  #checkov:skip=CKV_AWS_158:Encrypted with CloudWatch's AWS-managed key; a customer-managed KMS key costs $1/month.
  #checkov:skip=CKV_AWS_338:7 days keeps the cost near zero in a demo; production compliance would need 1 year.
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    sid = "WriteToTheFlowLogGroupOnly"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }

  statement {
    # The flow log service checks that the group exists. This action can't
    # be limited to one log group.
    sid       = "FindLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 600 # 10 minutes: cheaper than 1-minute records

  tags = { Name = "${var.name}-flow-logs" }
}
