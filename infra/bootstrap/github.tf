# Lets GitHub Actions use AWS with NO stored access keys.
#
# How it works: each workflow run asks GitHub for a short-lived signed token
# that says which repo, branch or event it is running for. AWS checks the
# signature with GitHub's OIDC provider and, if the conditions below match,
# hands back temporary credentials (valid about an hour) for one role.
#
# Two roles, each with only what its job needs:
#   deploy  only the main branch: push images, update the ECS services
#   plan    only pull requests: read-only, for `terraform plan` previews

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  cluster    = var.environment_name
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Trust policy builder: only this repo, and only the given branch or event.
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    deploy = "repo:${var.github_repository}:ref:refs/heads/main"
    plan   = "repo:${var.github_repository}:pull_request"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

# --- Deploy role (main branch only) -------------------------------------------

resource "aws_iam_role" "github_deploy" {
  name                 = "docflow-github-deploy"
  description          = "GitHub Actions on main: push images and deploy to ECS"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["deploy"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this API has no resource-level permissions
  }

  statement {
    sid = "PushAndInspectDocflowImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"] # these APIs have no resource-level permissions
  }

  statement {
    sid     = "DeployDocflowServices"
    actions = ["ecs:DescribeServices", "ecs:UpdateService"]
    resources = [
      "arn:aws:ecs:${local.region}:${local.account_id}:service/${local.cluster}/*",
    ]
  }

  statement {
    sid       = "CheckClusterExists"
    actions   = ["ecs:DescribeClusters"]
    resources = ["arn:aws:ecs:${local.region}:${local.account_id}:cluster/${local.cluster}"]
  }

  statement {
    # A new task definition revision names the app's roles; ECS needs
    # permission to hand them to the tasks. Only DocFlow's roles, only to ECS.
    sid       = "PassOnlyDocflowTaskRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.environment_name}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "FindAppUrlForSmokeTest"
    actions   = ["cloudfront:ListDistributions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-docflow"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# --- Plan role (pull requests only, read-only) --------------------------------

resource "aws_iam_role" "github_plan" {
  name                 = "docflow-github-plan"
  description          = "GitHub Actions on pull requests: read-only terraform plan"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["plan"].json
  max_session_duration = 3600
}

# Just enough to read the Terraform state and the data sources the plan
# looks up. No access to the files bucket, the database or any secret.
data "aws_iam_policy_document" "github_plan" {
  statement {
    sid       = "ReadTerraformState"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid = "ReadPlanLookups"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeManagedPrefixLists",
      "ecr:DescribeRepositories",
      "cloudfront:GetCachePolicy",
      "cloudfront:ListCachePolicies",
      "cloudfront:GetOriginRequestPolicy",
      "cloudfront:ListOriginRequestPolicies",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "plan-docflow"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan.json
}
