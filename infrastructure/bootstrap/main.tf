# ---------------------------------------------------------------------------
# Stage 1 of 2: the bootstrap.
#
# This stack creates ONLY the things that must exist before any pipeline can
# run, and it is applied once, by a human, from a laptop:
#
#   1. the S3 bucket that holds Terraform state (with native locking)
#   2. the GitHub OIDC identity provider
#   3. the two IAM roles GitHub Actions assumes
#
# It starts on LOCAL state, because the bucket it needs does not exist yet.
# After the first apply, move its own state into the bucket it just created:
# see ../../docs/BOOTSTRAP.md. That is the honest answer to the chicken and
# egg problem, and the bucket ends up holding the state of the code that
# created it.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"
  bucket = coalesce(
    var.state_bucket_name != "" ? var.state_bucket_name : null,
    "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}",
  )

  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Stack       = "bootstrap"
  }
}

# ---------------------------------------------------------------------------
# 1. Terraform state bucket
#
# No DynamoDB table. Locking is done by the S3 backend itself writing a
# .tflock object next to the state file (use_lockfile = true), which is the
# current approach; the DynamoDB lock table is deprecated.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  tags = {
    Name = local.bucket
  }
}

# Versioning is not optional: it is the only way back from a corrupted or
# truncated state file.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# State files are small; old versions are pure cost after a while.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# Refuse any request that did not arrive over TLS.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ---------------------------------------------------------------------------
# 2. GitHub OIDC identity provider
#
# This is the trust anchor. It lets AWS STS verify a JWT that GitHub minted
# for one specific workflow run, which is why no AWS access key ever has to
# live in the repository.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]

  tags = {
    Name = "github-actions-oidc"
  }

  lifecycle {
    # AWS validates and maintains the thumbprint for this well-known IdP
    # itself; the value above is the documented placeholder. Ignoring drift
    # keeps every later plan clean.
    ignore_changes = [thumbprint_list]
  }
}
