# ===========================================================================
# PHASE 3 — delivery
#
# The door, and the tenants. A load balancer in the public subnets, a target
# group pointed at /health, a listener on port 80, and the service that
# finally runs the blueprint from phase 2.
#
#   plan: 4 resources        apply: ~4 minutes
#
# Keep the URL open while this applies. The load balancer answers about two
# minutes before the first task passes its health check, so the page goes
# 503 -> 200 while the room watches. That transition is the whole lesson:
# a load balancer with no healthy targets is a door with nobody home.
# ===========================================================================

resource "aws_lb" "this" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb.id]

  # Public subnets, both zones. An ALB requires at least two, in different
  # Availability Zones — this is why phase 1 built two of everything.
  subnets = [for s in aws_subnet.public : s.id]

  idle_timeout               = 60
  enable_deletion_protection = false # teardown must never need a console click

  tags = {
    Name = local.name
  }
}

resource "aws_lb_target_group" "this" {
  name     = local.name
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id

  # Fargate with awsvpc networking registers IP addresses, not instances.
  target_type = "ip"

  # GET /health is deliberately the dumbest endpoint in the application: it
  # returns a constant. A health check that touches a database turns one
  # slow dependency into a full outage.
  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Tasks come and go on every deploy. Draining for the default 300 seconds
  # makes a demo rollout look broken.
  deregistration_delay = 15

  tags = {
    Name = local.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ---------------------------------------------------------------------------
# OWNERSHIP — the one subtlety in this repository. Read before editing.
#
# Two systems want to change this service:
#   - Terraform owns the service and the task-definition baseline
#   - the application pipeline registers a NEW task-definition revision on
#     every commit and points the service at it
#
# Without the lifecycle block below, every infrastructure apply would reset the
# service to whatever image this code last knew about — silently undoing the
# most recent application deploy. That is the classic failure mode.
#
# The precision matters: ignoring `task_definition` ignores WHICH REVISION the
# service points at. It does NOT ignore the aws_ecs_task_definition resource
# itself, which Terraform still manages — change cpu, memory or log config in
# phase 2 and a new revision still appears in the plan. What this stops is
# Terraform fighting the pipeline over the pointer.
#
# Verified after every apply by the infrastructure workflow, which curls
# /version and checks the running commit did not move backwards.
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Do not declare the deployment finished until the load balancer agrees the
  # new task is healthy, and roll back automatically if it never does.
  health_check_grace_period_seconds = 30
  wait_for_steady_state             = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    # The tasks run in the PRIVATE subnets and have no public IP. Nothing on
    # the internet can reach them directly; traffic arrives only through the
    # load balancer, and only on the application port.
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.project_name
    container_port   = var.app_port
  }

  tags = {
    Name = local.name
  }

  # The service cannot register targets before the listener exists.
  depends_on = [aws_lb_listener.http]

  lifecycle {
    # Read the note above before touching this.
    ignore_changes = [task_definition, desired_count]
  }
}

# ---- what this phase produced ------------------------------------------------

output "app_url" {
  description = "The public URL. This is the demo."
  value       = "http://${aws_lb.this.dns_name}"
}

output "ecs_service_name" {
  description = "Service the application pipeline deploys to"
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "Target group the tasks register into"
  value       = aws_lb_target_group.this.arn
}
