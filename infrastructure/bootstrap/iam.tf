# ---------------------------------------------------------------------------
# 3. The two delivery roles.
#
# Two roles, not one, is the security argument of the whole talk:
#   - the infrastructure pipeline may change infrastructure
#   - the application pipeline may push an image and roll the service
# Neither can do the other's job, and neither holds a long-lived key.
# ---------------------------------------------------------------------------

# Shared trust-policy shape. The two conditions that matter:
#   aud = sts.amazonaws.com  -> the token was minted for AWS, not for some
#                               other OIDC consumer
#   sub in [...]             -> the token came from THIS repository, on an
#                               allowed branch or environment
# Without the sub condition, any GitHub repository on earth could assume the
# role. That is the single most common mistake in OIDC setups.
data "aws_iam_policy_document" "github_trust" {
  for_each = {
    infra = var.infra_role_subjects
    app   = var.app_role_subjects
  }

  statement {
    sid     = "GitHubActionsAssumeRoleWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

# --- Terraform infrastructure role -----------------------------------------

resource "aws_iam_role" "terraform_infra" {
  name                 = "${local.name}-terraform-infra"
  description          = "Assumed by .github/workflows/infrastructure.yml to plan and apply the demo stack"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["infra"].json
  max_session_duration = 3600

  tags = {
    Name = "${local.name}-terraform-infra"
  }
}

# State access. Note what is NOT here: no s3:DeleteBucket, and no access to
# any other bucket in the account.
data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid    = "ReadWriteStateAndLock"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject", # required to release the .tflock object
    ]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

resource "aws_iam_role_policy" "terraform_state" {
  name   = "terraform-state"
  role   = aws_iam_role.terraform_infra.id
  policy = data.aws_iam_policy_document.terraform_state.json
}

# Provisioning permissions, scoped by SERVICE rather than by resource.
#
# Documented exposure: this is broader than a production role should be. A
# role that can create VPCs, load balancers and IAM roles can do real damage
# in the account it lives in, which is why this demo belongs in an isolated
# sandbox account. It is still not AdministratorAccess: it cannot touch
# billing, Organizations, other buckets, EC2 instances, RDS, or any service
# not listed below.
data "aws_iam_policy_document" "terraform_provision" {
  statement {
    sid    = "ProvisionDemoStack"
    effect = "Allow"
    actions = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*RouteTable*",
      "ec2:*Route",
      "ec2:*InternetGateway*",
      "ec2:*SecurityGroup*",
      "ec2:*Tags",
      "ec2:Describe*",
      "elasticloadbalancing:*",
      "ecs:*",
      "ecr:*",
      "logs:*",
      "application-autoscaling:*",
    ]
    resources = ["*"]
  }

  # Terraform creates the ECS task and execution roles, so it needs IAM. The
  # path constraint is the fence: this role can only manage roles it created
  # under /code-busters/, so it cannot escalate by editing an admin role.
  statement {
    sid    = "ManageDemoServiceRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PassRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account}:role/${var.project_name}/*"]
  }

  statement {
    sid       = "ReadOnlyIamLookups"
    effect    = "Allow"
    actions   = ["iam:ListRoles", "iam:ListPolicies", "iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "terraform_provision" {
  name   = "terraform-provision"
  role   = aws_iam_role.terraform_infra.id
  policy = data.aws_iam_policy_document.terraform_provision.json
}

# --- Application deploy role -----------------------------------------------

resource "aws_iam_role" "app_deploy" {
  name                 = "${local.name}-app-deploy"
  description          = "Assumed by .github/workflows/application.yml to push an image and roll the ECS service"
  assume_role_policy   = data.aws_iam_policy_document.github_trust["app"].json
  max_session_duration = 3600

  tags = {
    Name = "${local.name}-app-deploy"
  }
}

# Deliberately narrow. This role cannot create a VPC, cannot read Terraform
# state, and cannot deploy to any cluster but this one.
data "aws_iam_policy_document" "app_deploy" {
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid    = "PushToOneRepository"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = ["arn:${local.partition}:ecr:${var.aws_region}:${local.account}:repository/${local.name}"]
  }

  # RegisterTaskDefinition and Describe* are account-level actions in ECS;
  # they cannot be scoped to one resource.
  statement {
    sid    = "RegisterTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "RollOneService"
    effect = "Allow"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = ["arn:${local.partition}:ecs:${var.aws_region}:${local.account}:service/${local.name}/${local.name}"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${local.partition}:ecs:${var.aws_region}:${local.account}:cluster/${local.name}"]
    }
  }

  statement {
    sid       = "InspectTasks"
    effect    = "Allow"
    actions   = ["ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${local.partition}:ecs:${var.aws_region}:${local.account}:cluster/${local.name}"]
    }
  }

  # Registering a task definition means handing ECS two roles. Without this
  # the deploy fails; with it unscoped, this role could hand ECS ANY role in
  # the account and run code as it. Hence the exact two ARNs.
  statement {
    sid     = "PassOnlyTheTaskRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account}:role/${var.project_name}/${local.name}-task-execution",
      "arn:${local.partition}:iam::${local.account}:role/${var.project_name}/${local.name}-task",
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Needed to resolve the public URL for the smoke test.
  statement {
    sid       = "ReadLoadBalancerDns"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "app_deploy" {
  name   = "app-deploy"
  role   = aws_iam_role.app_deploy.id
  policy = data.aws_iam_policy_document.app_deploy.json
}
