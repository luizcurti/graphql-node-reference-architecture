output "api_url" {
  description = "Base URL over HTTPS: GraphQL (HTTP and WebSocket subscriptions) at / and /graphql."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "ecs_services" {
  description = "Every ECS service of the stack (API and Kafka)."
  value       = [aws_ecs_service.app.name, aws_ecs_service.kafka.name]
}

output "metrics_token_parameter" {
  description = "SSM SecureString holding the X-Metrics-Token for /metrics."
  value       = aws_ssm_parameter.secret["METRICS_TOKEN"].name
}

# Everything the deploy job needs to run the one-off migration + seed task.
output "db_setup_task" {
  value = {
    task_definition = aws_ecs_task_definition.db_setup.arn
    subnets         = aws_subnet.public[*].id
    security_group  = aws_security_group.app.id
    log_group       = aws_cloudwatch_log_group.app.name
  }
}
