terraform {
  # S3 native state locking (use_lockfile) is what replaces the old DynamoDB
  # lock table. Do not lower this constraint; on an older CLI the backend
  # silently falls back to no locking.
  required_version = "~> 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
