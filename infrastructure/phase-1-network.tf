# ===========================================================================
# PHASE 1 — the network
#
# Nothing runs yet. This phase builds the place things will run in:
# a VPC across two Availability Zones, a public subnet and a private subnet
# in each, a way out to the internet, and the two security groups that decide
# who may talk to whom.
#
#   plan: ~26 resources      apply: ~2.5 minutes (the NAT gateways)
#
# High availability starts here, not at the load balancer: two zones, two
# NAT gateways, two of every route. Lose a zone and the other one still has
# a complete path in and out.
# ===========================================================================

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.name
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = local.name
  }
}

# ---- subnets ---------------------------------------------------------------
# for_each keyed by Availability Zone rather than count: removing a zone later
# destroys only that zone's subnet instead of renumbering every subnet after
# it, which with count would recreate live resources.

resource "aws_subnet" "public" {
  for_each = local.public_subnet_cidrs

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnet_cidrs

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  # No public IP. Nothing in here is reachable from the internet, which is the
  # entire point of putting the application tasks here.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-private-${each.key}"
    Tier = "private"
  }
}

# ---- public routing --------------------------------------------------------
# One shared route table: every public subnet wants the same default route.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---- egress for the private subnets ----------------------------------------
# One NAT gateway per zone, each with its own Elastic IP. One NAT would be
# cheaper and would also mean that losing its zone takes the other zone's
# outbound traffic with it — no image pulls, no logs. That is the tradeoff
# this architecture deliberately does not make.

resource "aws_eip" "nat" {
  for_each = local.public_subnet_cidrs

  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-${each.key}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = local.public_subnet_cidrs

  # The NAT gateway lives in the PUBLIC subnet and serves the private one.
  # Putting it in the private subnet is the classic mistake: it would have no
  # route out itself.
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${local.name}-${each.key}"
  }

  depends_on = [aws_internet_gateway.this]
}

# One route table per private subnet, because each points at the NAT gateway
# in its OWN zone. Sharing one table would send half the traffic across a
# zone boundary and defeat the redundancy above.
resource "aws_route_table" "private" {
  for_each = local.private_subnet_cidrs

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-private-${each.key}"
  }
}

resource "aws_route" "private_default" {
  for_each = local.private_subnet_cidrs

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.key].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---- security groups --------------------------------------------------------
# A security group is a rule set, not a place. These two are the whole access
# model: the internet may reach the load balancer, the load balancer may reach
# the tasks, and nothing else is permitted inbound anywhere.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ingress to the Code Busters load balancer"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet. Demo only: no domain, so no certificate and no HTTPS listener."

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward to the tasks on the application port only"

  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

resource "aws_security_group" "tasks" {
  name        = "${local.name}-tasks"
  description = "Code Busters Fargate tasks"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${local.name}-tasks"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# THE line worth reading aloud. The source is a SECURITY GROUP, not a CIDR
# block: "whatever is the load balancer may connect, on one port". The rule
# keeps working when the load balancer's addresses change, and no IP range
# anywhere else in the world matches it.
resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id = aws_security_group.tasks.id
  description       = "Application port, from the load balancer security group only"

  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
}

# Outbound stays open: the task has to reach ECR for its image and CloudWatch
# for its logs. There is no inbound counterpart to this, and no SSH anywhere
# in this VPC.
resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound to ECR and CloudWatch Logs via the NAT gateway"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

# ---- what this phase produced ------------------------------------------------

output "vpc_id" {
  description = "VPC created in phase 1"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnets, one per Availability Zone"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Private subnets, one per Availability Zone"
  value       = [for s in aws_subnet.private : s.id]
}

output "nat_gateway_public_ips" {
  description = "The addresses the tasks appear to come from"
  value       = [for e in aws_eip.nat : e.public_ip]
}
