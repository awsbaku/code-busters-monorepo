output "state_bucket" {
  description = "Terraform state bucket. Put this in infrastructure/backend.tf and in the workflows."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_region" {
  description = "Region of the state bucket, for the backend block"
  value       = var.aws_region
}

output "terraform_infra_role_arn" {
  description = "Set as the AWS_INFRA_ROLE_ARN repository variable"
  value       = aws_iam_role.terraform_infra.arn
}

output "app_deploy_role_arn" {
  description = "Set as the AWS_APP_ROLE_ARN repository variable"
  value       = aws_iam_role.app_deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider in use"
  value       = local.oidc_provider_arn
}

output "github_variables_to_set" {
  description = "Copy/paste helper: the repository variables the workflows expect"
  value = {
    AWS_REGION         = var.aws_region
    AWS_INFRA_ROLE_ARN = aws_iam_role.terraform_infra.arn
    AWS_APP_ROLE_ARN   = aws_iam_role.app_deploy.arn
    TF_STATE_BUCKET    = aws_s3_bucket.state.id
    ECR_REPOSITORY     = local.name
    ECS_CLUSTER        = local.name
    ECS_SERVICE        = local.name
    ECS_TASK_FAMILY    = local.name
  }
}
