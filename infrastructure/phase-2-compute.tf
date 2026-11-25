# ===========================================================================
# PHASE 2 — the blueprint
#
# AWS learns how to run the container, and still runs nothing.
#
# A cluster is an empty namespace. A task definition is a recipe: image, cpu,
# memory, ports, roles, where the logs go. Registering it starts nothing — and
# that separation is the thing worth showing. "AWS now knows exactly how to run
# this. It just hasn't been asked to."
#
#   plan: 6 resources        apply: ~20 seconds
# ===========================================================================

# ---- where the container's output goes --------------------------------------
# Created before the task definition that references it: ECS will not start a
# container whose log group is missing.
#
# log_retention_days is also the best live-change knob in the whole stack —
# 7 to 14 is a one-line diff, a readable plan, no replacement, three seconds.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "/ecs/${local.name}"
  }
}

# ---- the two roles the task uses --------------------------------------------
# Not to be confused with the two pipeline roles in bootstrap/.
#
#   execution role  the ECS agent uses it BEFORE the container starts:
#                   pull the image, create the log stream
#   task role       the application code uses it AT RUNTIME
#
# Both sit under the /code-busters/ IAM path, which is the fence that lets the
# Terraform pipeline role manage them without being able to touch any other
# role in the account.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  path               = "/${var.project_name}/"
  description        = "Pulls the image from ECR and writes to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name}-task-execution"
  }
}

# The AWS-managed policy for exactly this job: ECR pull and log writes,
# nothing else.
resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The application serves one HTML page and calls no AWS API, so this role has
# no policies at all. It exists anyway: it is the correct place to add a
# permission later, and an explicit empty role documents that the container
# was given nothing on purpose.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  path               = "/${var.project_name}/"
  description        = "Runtime role for the Code Busters container. Intentionally has no permissions."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${local.name}-task"
  }
}

# ---- the cluster ------------------------------------------------------------
# An empty namespace for tasks. Creating it costs nothing and starts nothing.
resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled" # bills per metric; off for a short-lived demo
  }

  tags = {
    Name = local.name
  }
}

# ---- the recipe ---------------------------------------------------------------
# Registering a revision does not run anything. Phase 3 points a service at it.
#
# The image is the seed tag the bootstrap pushed. It has to resolve to a real
# image already in ECR, or the service created in phase 3 cannot start.
resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = var.project_name
    image     = "${local.ecr_repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = var.app_port
      protocol      = "tcp"
    }]

    environment = [
      { name = "APP_PORT", value = tostring(var.app_port) },
      { name = "APP_ENV", value = var.environment },
      { name = "APP_VERSION", value = var.app_version },
      { name = "APP_NAME", value = "Code Busters" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])

  tags = {
    Name = local.name
  }
}

# ---- what this phase produced --------------------------------------------------

output "ecs_cluster_name" {
  description = "Cluster created in phase 2"
  value       = aws_ecs_cluster.this.name
}

output "task_definition_arn" {
  description = "The registered revision. Nothing is running it yet."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "Where container output will appear once something runs"
  value       = aws_cloudwatch_log_group.app.name
}
