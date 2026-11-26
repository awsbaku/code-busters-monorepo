# Shared lookups and names. Every phase file reads from here.

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-${var.environment}"

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /24 per subnet out of the /16, public first then private, so the ranges
  # stay readable on a slide:
  #   az a -> public 10.42.0.0/24   private 10.42.10.0/24
  #   az b -> public 10.42.1.0/24   private 10.42.11.0/24
  public_subnet_cidrs = {
    for idx, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, idx)
  }
  private_subnet_cidrs = {
    for idx, az in local.azs : az => cidrsubnet(var.vpc_cidr, 8, idx + 10)
  }

  # The registry is created by the bootstrap, not by any phase: the service in
  # phase 3 needs an image to pull the moment it is created.
  # The public name of the demo. Phase 3 attaches it to the load balancer.
  fqdn = "${var.subdomain}.${var.domain_name}"

  ecr_repository_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name}"

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "awsbaku/code-busters-monorepo"
  }
}
