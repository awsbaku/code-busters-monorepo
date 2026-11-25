terraform {
  # Partial configuration. The bucket name is account-specific, so it is
  # supplied at init time instead of being committed:
  #
  #   terraform init \
  #     -backend-config="bucket=code-buster-tfstate-<account-id>" \
  #     -backend-config="region=eu-central-1"
  #
  # use_lockfile = true is the current S3 state-locking mechanism: the
  # backend writes a <key>.tflock object beside the state file and takes the
  # lock through S3 conditional writes. The old DynamoDB lock table is
  # deprecated and is deliberately absent from this repository.
  backend "s3" {
    key          = "demo/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
