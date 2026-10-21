# ElastiCache Redis 7, required in production: GraphQL subscriptions (Redis PubSub), the
# distributed login rate limiter and the JWT verification cache. The AUTH token requires
# in-transit encryption, so REDIS_URL uses the rediss:// scheme, which ioredis connects to over
# TLS. `noeviction`: rate-limit counters and cached tokens must expire by their own TTL, not be
# evicted early. One node, no replica: the demo doesn't need failover.

resource "random_password" "redis_auth" {
  length  = 48
  special = false # ElastiCache AUTH tokens only allow a subset of special characters
}

resource "aws_elasticache_parameter_group" "main" {
  name   = "${local.name}-redis7"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = local.name
  description          = "${local.name} subscriptions, login rate limiter and token cache"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  parameter_group_name = aws_elasticache_parameter_group.main.name
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  automatic_failover_enabled = false
  apply_immediately          = true
  snapshot_retention_limit   = 0
}
