# A small VPC with two public subnets and no NAT gateway: the ALB and the RDS and ElastiCache
# subnet groups need two AZs, and the Fargate tasks get a public IP to reach ECR, ECR Public and
# SSM (cheaper than a NAT). Nothing but the ALB accepts traffic from outside the VPC:
#   CloudFront -> ALB -> API task -> MySQL, Redis, Kafka
#   (the one-off db-setup task shares the API task's security group)

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # Cloud Map's private DNS namespace needs both
  enable_dns_support   = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# CloudFront's origin-facing IP ranges, as an AWS-managed prefix list.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# --- ALB -----------------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "HTTP from CloudFront only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To the API task"
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# --- API ---------------------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "API task, reachable only from the ALB"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "From the ALB"
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# HTTPS out: ECR, CloudWatch Logs and SSM.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_to_backends" {
  for_each = {
    mysql = { port = 3306, sg = aws_security_group.db.id }
    redis = { port = 6379, sg = aws_security_group.redis.id }
    kafka = { port = 9092, sg = aws_security_group.kafka.id }
  }

  security_group_id            = aws_security_group.app.id
  description                  = "To ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = each.value.sg
}

# --- Backends: each one only admits the API task ---------------------------------

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "MySQL, reachable only from the API task"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-db" }
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "Redis, reachable only from the API task"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-redis" }
}

resource "aws_security_group" "kafka" {
  name        = "${local.name}-kafka"
  description = "Kafka, reachable only from the API task"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-kafka" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_app" {
  for_each = {
    mysql = { port = 3306, sg = aws_security_group.db.id }
    redis = { port = 6379, sg = aws_security_group.redis.id }
    kafka = { port = 9092, sg = aws_security_group.kafka.id }
  }

  security_group_id            = each.value.sg
  description                  = "From the API task"
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  referenced_security_group_id = aws_security_group.app.id
}

# The Kafka task pulls its image from Docker Hub and ships logs to CloudWatch.
resource "aws_vpc_security_group_egress_rule" "kafka_https" {
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS to Docker Hub and CloudWatch Logs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
