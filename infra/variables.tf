variable "project_name" {
  description = "Prefix of every resource name. Must match project_name in ../bootstrap (the deploy role is scoped by it)."
  type        = string
  default     = "graphql-ref"
}

variable "aws_region" {
  description = "AWS region of the stack (CloudFront itself is global)."
  type        = string
  default     = "eu-west-2"
}

variable "app_image_tag" {
  description = "Tag of the app image in ECR, pushed by the CI deploy job before apply (the commit SHA)."
  type        = string
  default     = "latest"
}

variable "kafka_image" {
  description = "Kafka image (the docker-compose `kafka` service, KRaft mode, single node)."
  type        = string
  default     = "apache/kafka:3.9.0"
}

variable "vpc_cidr" {
  description = "CIDR of the VPC. Two public /24 subnets are carved out of it."
  type        = string
  default     = "10.49.0.0/16"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is free-tier eligible on new accounts."
  type        = string
  default     = "db.t4g.micro"
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the container logs."
  type        = number
  default     = 14
}
