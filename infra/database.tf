# MySQL 8.4. docker-compose and CI use 8.0, whose RDS standard support has ended (extended
# support is billed extra); the app's Knex migrations run the same on 8.4. The master password
# is generated and stored by RDS in Secrets Manager; ECS injects it as DATABASE_PASSWORD, so it
# never appears in Terraform state or the task definitions. Migrations and seed data are applied
# by the one-off `db-setup` task in app.tf.
#
# TLS: DATABASE_SSL=rds verifies the server certificate against the Amazon RDS CA bundle that
# mysql2 ships. The instance is not publicly accessible and its security group only admits the
# app tasks.

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = "mysql"
  engine_version = "8.4"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "graphql_mysql"
  username                    = "app"
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # Demo stack, torn down by the Destroy workflow: no final snapshot, no deletion protection.
  backup_retention_period    = 1
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = true
}
