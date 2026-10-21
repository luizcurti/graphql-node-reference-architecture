# The GraphQL API on ECS Fargate behind an ALB (HTTP queries/mutations and graphql-ws
# subscriptions over WebSocket, both through CloudFront), plus Kafka as its own Fargate service,
# reached at kafka.<name>.internal through a Cloud Map private DNS name. Jaeger, Prometheus and
# Grafana (the `observability` profile) are not deployed: OTEL_EXPORTER_OTLP_ENDPOINT stays
# unset (no tracing overhead) and logs go to CloudWatch; /metrics stays available behind
# X-Metrics-Token.

locals {
  app_port = 4003

  kafka_host = "kafka.${aws_service_discovery_private_dns_namespace.main.name}"
  app_url    = "https://${aws_cloudfront_distribution.main.domain_name}"

  # Shared by the API and the one-off db-setup task.
  db_environment = [
    { name = "NODE_ENV", value = "production" },
    { name = "DOTENV_CONFIG_QUIET", value = "true" },
    { name = "DATABASE_CLIENT", value = "mysql2" },
    { name = "DATABASE_HOST", value = aws_db_instance.main.address },
    { name = "DATABASE_PORT", value = tostring(aws_db_instance.main.port) },
    { name = "DATABASE_NAME", value = aws_db_instance.main.db_name },
    { name = "DATABASE_USER", value = aws_db_instance.main.username },
    { name = "DATABASE_SSL", value = "rds" },
  ]
  db_password = { name = "DATABASE_PASSWORD", valueFrom = "${aws_db_instance.main.master_user_secret[0].secret_arn}:password::" }
}

resource "aws_ecr_repository" "app" {
  name                 = "${local.name}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Destroy also removes the pushed images

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

# One group for every container; each writes under its own stream prefix.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}-app"
  retention_in_days = var.log_retention_days
}

# --- Secrets (SSM SecureString, AWS-managed key) -------------------------------------------

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "metrics_token" {
  length  = 40
  special = false
}

locals {
  secrets = {
    JWT_SECRET    = random_password.jwt_secret.result
    METRICS_TOKEN = random_password.metrics_token.result
    REDIS_URL     = "rediss://:${random_password.redis_auth.result}@${aws_elasticache_replication_group.main.primary_endpoint_address}:6379"
  }
}

resource "aws_ssm_parameter" "secret" {
  for_each = toset(["JWT_SECRET", "METRICS_TOKEN", "REDIS_URL"])

  name  = "/${local.name}/${each.key}"
  type  = "SecureString"
  value = local.secrets[each.key]
}

# --- IAM -------------------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Used by ECS to pull the images, write logs and inject the secrets as environment variables.
# None of the containers calls an AWS API, so there is no task role.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-app-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "AppSecrets"
    actions   = ["ssm:GetParameters"]
    resources = [for parameter in aws_ssm_parameter.secret : parameter.arn]
  }

  statement {
    sid       = "DatabasePassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# --- ECS cluster and service discovery -------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${local.name}.internal"
  description = "Private DNS names of ${local.name} services"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "kafka" {
  name = "kafka"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# --- Kafka -------------------------------------------------------------------------------------
# A single KRaft node (broker + controller), configured like the docker-compose `kafka` service
# but advertising its Cloud Map name, without persistence across task restarts: fine for the
# comment.created event backbone of a demo. The deploy waits for it before starting the API,
# whose comment consumer joins its consumer group at startup.

resource "aws_ecs_task_definition" "kafka" {
  family                   = "${local.name}-kafka"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "kafka"
    image     = var.kafka_image
    essential = true

    portMappings = [{ containerPort = 9092, protocol = "tcp" }]

    environment = [
      { name = "KAFKA_NODE_ID", value = "1" },
      { name = "KAFKA_PROCESS_ROLES", value = "broker,controller" },
      { name = "KAFKA_LISTENERS", value = "PLAINTEXT://:9092,CONTROLLER://:9093" },
      { name = "KAFKA_ADVERTISED_LISTENERS", value = "PLAINTEXT://${local.kafka_host}:9092" },
      { name = "KAFKA_CONTROLLER_LISTENER_NAMES", value = "CONTROLLER" },
      { name = "KAFKA_CONTROLLER_QUORUM_VOTERS", value = "1@localhost:9093" },
      { name = "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP", value = "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT" },
      { name = "KAFKA_INTER_BROKER_LISTENER_NAME", value = "PLAINTEXT" },
      { name = "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR", value = "1" },
      { name = "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR", value = "1" },
      { name = "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR", value = "1" },
      { name = "KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS", value = "0" },
      # The image defaults to a 1 GiB heap; leave room in the 1 GiB task for the page cache.
      { name = "KAFKA_HEAP_OPTS", value = "-Xms384m -Xmx384m" },
    ]

    # A plain TCP check on the listener: the broker's own CLI tools would follow the advertised
    # Cloud Map name, which only resolves once ECS has registered this (healthy) task.
    healthCheck = {
      command     = ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/9092' || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 5
      startPeriod = 60
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "kafka"
      }
    }
  }])
}

resource "aws_ecs_service" "kafka" {
  name            = "${local.name}-kafka"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.kafka.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  # Never two brokers with the same node ID at once: the old task stops before the new one starts.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.kafka.id]
    assign_public_ip = true # pulls the image from Docker Hub without a NAT gateway
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kafka.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # The API below is only created once Kafka is healthy and registered.
  wait_for_steady_state = true

  depends_on = [aws_iam_role_policy.execution_secrets]
}

# --- Migrations + seed (one-off task) ----------------------------------------------------------
# The app image doesn't migrate on boot (see k8s/README.md); docker-compose and CI run
# `npm run db:setup` separately. The deploy job runs this task, the compiled equivalent, after
# every apply: migrate:latest, then the seeds, which truncate and reload the demo data (the
# Postman collection run by the smoke tests depends on those fixed rows).

resource "aws_ecs_task_definition" "db_setup" {
  family                   = "${local.name}-db-setup"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "db-setup"
    image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
    essential = true

    # `npm run db:setup`, against the compiled knexfile and migrations in dist/.
    command = ["sh", "-c", join(" && ", [
      "node node_modules/knex/bin/cli.js --knexfile dist/knex/knexfile.js migrate:latest",
      "node node_modules/knex/bin/cli.js --knexfile dist/knex/knexfile.js seed:run",
    ])]

    environment = local.db_environment
    secrets     = [local.db_password]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "db-setup"
      }
    }
  }])
}

# --- API ---------------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
    essential = true

    # tini as PID 1 (zombie reaping, signal forwarding).
    linuxParameters = { initProcessEnabled = true }

    portMappings = [{ containerPort = local.app_port, protocol = "tcp" }]

    environment = concat(local.db_environment, [
      { name = "PORT", value = tostring(local.app_port) },
      # The login cookie is SameSite=None; Secure, so cross-site browser clients must be
      # allowlisted. The API's own origin is the only one by default.
      { name = "ALLOWED_ORIGINS", value = local.app_url },
      { name = "KAFKA_BROKERS", value = "${local.kafka_host}:9092" },
      { name = "KAFKA_CLIENT_ID", value = "graphql-node" },
      { name = "KAFKA_CONSUMER_GROUP", value = "graphql-node-subscriptions" },
      { name = "LOG_LEVEL", value = "info" },
    ])

    secrets = concat([local.db_password], [
      for key in ["JWT_SECRET", "METRICS_TOKEN", "REDIS_URL"] :
      { name = key, valueFrom = aws_ssm_parameter.secret[key].arn }
    ])

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true

  # graphql-ws keeps subscriptions open with its own pings; this only bounds silent connections.
  idle_timeout = 120
}

resource "aws_lb_target_group" "app" {
  name        = "${local.name}-app"
  port        = local.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 10

  # Liveness, not /ready: a slow MySQL must not make the ALB drain a healthy process.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_ecs_service" "app" {
  name            = "${local.name}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  health_check_grace_period_seconds = 60

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # reaches ECR, SSM and Secrets Manager without a NAT gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = local.app_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http, aws_iam_role_policy.execution_secrets, aws_ecs_service.kafka]
}
