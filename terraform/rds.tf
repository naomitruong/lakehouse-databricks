# =============================================================
# Amazon RDS for MySQL — replaces the self-hosted mysql:8.0 container.
# Binlog (ROW format) is enabled via a custom parameter group so
# Debezium can capture CDC events, exactly like the original
# docker-compose `command:` flags did.
# =============================================================

# Public subnets only. When a subnet group mixes a public and a private
# subnet in the same AZ, RDS is free to place the instance's ENI in
# either one — it picked the private subnet here, which routes 0.0.0.0/0
# via the NAT Gateway instead of the Internet Gateway, so the
# publicly_accessible=true public IP was unreachable from outside the
# VPC (SG was correct; the subnet's route table was the actual block).
#
# The RDS API refuses to drop a subnet from a group while an instance's
# ENI is still sitting in it (InvalidParameterValue: subnet in use), so
# this can't be a plain in-place edit of the original group. Instead the
# group name changes (forces replacement) with create_before_destroy: the
# new public-only group is created, aws_db_instance.mysql_source is
# re-pointed at it (which relocates the ENI), and only then is the old
# group — now unused — destroyed.
resource "aws_db_subnet_group" "pipeline" {
  name       = "${var.project_name}-db-subnet-public"
  subnet_ids = aws_subnet.public[*].id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-db-subnet-public"
  }
}

resource "aws_db_parameter_group" "mysql_cdc" {
  name   = "${var.project_name}-mysql-cdc"
  family = "mysql8.0"

  parameter {
    name  = "binlog_format"
    value = "ROW"
  }

  parameter {
    name  = "binlog_row_image"
    value = "FULL"
  }
}

# RDS has no binlog_retention_hours parameter — retention is set at runtime
# via `CALL mysql.rds_set_configuration('binlog retention hours', N);`
# (see scripts/init_mysql_cdc.sql), which replaces the --server-id /
# --log-bin docker-compose command flags the self-hosted mysqld used.

resource "aws_db_instance" "mysql_source" {
  identifier     = "${var.project_name}-mysql-source"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "source_db"
  username = var.db_username
  password = var.db_password

  parameter_group_name = aws_db_parameter_group.mysql_cdc.name

  multi_az               = var.db_multi_az
  publicly_accessible    = true
  db_subnet_group_name   = aws_db_subnet_group.pipeline.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # RDS MySQL only enables binary logging when automated backups are on
  # (backup_retention_period > 0) — required for Debezium's binlog capture.
  backup_retention_period   = 1
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  apply_immediately         = true
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-final-snapshot" : null
  deletion_protection       = var.environment == "prod"
  copy_tags_to_snapshot     = true

  performance_insights_enabled = true

  tags = {
    Name = "${var.project_name}-mysql-source"
  }
}
