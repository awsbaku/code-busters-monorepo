# ===========================================================================
# PHASE 3 — delivery
#
# The door, the name on it, and the tenants. A load balancer in the public
# subnets, a TLS certificate proved by DNS, a real hostname pointed at it,
# and the service that finally runs the blueprint from phase 2.
#
#   plan: 11 resources       apply: ~5 minutes
#
# Keep the URL open while this applies. The load balancer answers about two
# minutes before the first task passes its health check, so the page goes
# 503 -> 200 while the room watches. That transition is the whole lesson:
# a load balancer with no healthy targets is a door with nobody home.
# ===========================================================================

# ---------------------------------------------------------------------------
# NAME AND CERTIFICATE
#
# The hosted zone already exists and is NOT managed here — a data source, not
# a resource. Terraform reads it; it will never delete it. That distinction is
# worth saying out loud: data sources are how Terraform code reaches things
# somebody else owns.
#
# The certificate IS created here, and it has to be. ACM certificates are
# REGIONAL. There is already a *.huseynov.net certificate in this account, but
# it lives in us-east-1 because CloudFront requires that region, and an ALB in
# eu-central-1 cannot attach it. Same domain, same account, wrong region.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  name         = "${var.domain_name}."
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  domain_name       = local.fqdn
  validation_method = "DNS"

  tags = {
    Name = local.name
  }

  # Replace before destroy — a listener in use cannot drop its certificate.
  lifecycle {
    create_before_destroy = true
  }
}

# ACM asks for proof you control the name. Because the zone is in this same
# account, Terraform can write that proof itself, and the whole exchange
# finishes in under two minutes with nobody touching a console.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# This resource creates nothing. It is a gate: everything downstream waits
# here until ACM confirms the certificate is ISSUED.
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

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

# Port 80 forwards nothing. It exists only to send browsers to port 443, so
# that typing the bare hostname still works and still ends up encrypted.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"

  # TLS stops at the load balancer. Traffic from here to the task crosses only
  # private subnets inside the VPC, on the application port, from one security
  # group to one other security group.
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# The payoff. An alias record costs nothing, needs no TTL tuning, and points
# at the load balancer by name rather than by address — which matters, because
# an ALB's addresses change without warning.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# Phase 1 opened port 80 on the load balancer. The certificate is new, so the
# port it answers on is new too.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
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
  depends_on = [aws_lb_listener.https]

  lifecycle {
    # Read the note above before touching this.
    ignore_changes = [task_definition, desired_count]
  }
}

# ---- what this phase produced ------------------------------------------------

output "app_url" {
  description = "The public URL. This is the demo."
  value       = "https://${aws_route53_record.app.fqdn}"
}

output "alb_dns_name" {
  description = "The load balancer's own name, behind the alias record"
  value       = aws_lb.this.dns_name
}

output "ecs_service_name" {
  description = "Service the application pipeline deploys to"
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "Target group the tasks register into"
  value       = aws_lb_target_group.this.arn
}
