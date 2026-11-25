# Complete from the first phase. No phase ever edits this file, so every
# phase pull request is a single new file and nothing else.

variable "project_name" {
  description = "Name prefix for every resource"
  type        = string
  default     = "code-busters"

  nullable = false
}

variable "environment" {
  description = "Environment name used in names and tags"
  type        = string
  default     = "demo"

  validation {
    condition     = contains(["demo", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: demo, staging, prod."
  }

  nullable = false
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"

  nullable = false
}

# ---- networking -----------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.42.0.0/16"

  nullable = false
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones. Two is the minimum: an Application Load
    Balancer requires subnets in at least two, and one task per zone is what
    makes the service survive losing a zone.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }

  nullable = false
}

# ---- application ----------------------------------------------------------

variable "app_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8080

  nullable = false
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256

  nullable = false
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Must pair validly with task_cpu."
  type        = number
  default     = 512

  nullable = false
}

variable "desired_count" {
  description = "Running tasks. Two means one per Availability Zone."
  type        = number
  default     = 2

  nullable = false
}

variable "app_version" {
  description = "Version string shown on the page, for the baseline task definition"
  type        = string
  default     = "0.1.0"

  nullable = false
}

variable "image_tag" {
  description = <<-EOT
    Image tag for the task-definition BASELINE only. The bootstrap pushes this
    tag so the service has something to pull the moment it is created. The
    application pipeline deploys immutable commit SHAs and never changes this
    value; see the ownership note in phase-3-delivery.tf.
  EOT
  type        = string
  default     = "seed"

  nullable = false
}

variable "log_retention_days" {
  description = "CloudWatch log retention. A real cost control, and a good live-change knob."
  type        = number
  default     = 7

  nullable = false
}
