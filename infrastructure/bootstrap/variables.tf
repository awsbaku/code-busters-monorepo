variable "project_name" {
  description = "Name prefix for every resource created here"
  type        = string
  default     = "code-busters"

  nullable = false
}

variable "environment" {
  description = "Environment name used in tags and resource names"
  type        = string
  default     = "demo"

  nullable = false
}

variable "aws_region" {
  description = "AWS region for the state bucket and IAM resources"
  type        = string
  default     = "eu-central-1"

  nullable = false
}

variable "state_bucket_name" {
  description = <<-EOT
    Globally unique name for the Terraform state bucket. S3 bucket names are
    global, so this must be unique across all of AWS. Leave empty to derive
    "<project>-tfstate-<account-id>", which is unique by construction.
  EOT
  type        = string
  default     = ""

  nullable = false
}

variable "github_owner" {
  description = "GitHub organisation or user that owns the repository"
  type        = string
  default     = "awsbaku"

  nullable = false
}

variable "github_repo" {
  description = "Repository name inside github_owner"
  type        = string
  default     = "code-busters-monorepo"

  nullable = false
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the IAM OIDC identity provider for token.actions.githubusercontent.com.
    An AWS account may only hold ONE provider per URL, so set this to false if
    another stack in this account already created it, and pass its ARN in
    existing_oidc_provider_arn instead.
  EOT
  type        = bool
  default     = true

  nullable = false
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used when create_oidc_provider is false"
  type        = string
  default     = ""

  nullable = false
}

variable "infra_role_subjects" {
  description = <<-EOT
    OIDC "sub" claim values allowed to assume the Terraform infrastructure role.

    READ THIS BEFORE YOU APPLY. There are two subject formats in the wild and
    copying the wrong one produces a role nobody can assume:

      legacy (repos created before 15 July 2026)
        repo:OWNER/REPO:ref:refs/heads/main
        repo:OWNER/REPO:environment:demo-infra

      immutable (repos created on or after 15 July 2026)
        uses numeric owner and repository IDs rather than names

    Do not guess. Print the real claim once, from the real repository:

      - run any workflow with `permissions: id-token: write`
      - add a step that requests the token and decodes only its CLAIMS
        (never echo the raw JWT), or read the claim from the CloudTrail
        AssumeRoleWithWebIdentity event after a first failed attempt
      - also check: gh api /repos/OWNER/REPO/actions/oidc/customization/sub

    Wildcards are permitted inside a value (for example ":environment:*") but
    never use "repo:OWNER/*" and never "*" alone.
  EOT
  type        = list(string)

  nullable = false
}

variable "app_role_subjects" {
  description = "OIDC \"sub\" claim values allowed to assume the application deploy role. Same format rules as infra_role_subjects."
  type        = list(string)

  nullable = false
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone the infrastructure role may write records into"
  type        = string
}
