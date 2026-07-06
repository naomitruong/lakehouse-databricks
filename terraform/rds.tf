# =============================================================
# Amazon RDS for MySQL — replaces the self-hosted mysql:8.0 container.
# Binlog (ROW format) is enabled via a custom parameter group so
# Debezium can capture CDC events, exactly like the original
# docker-compose `command:` flags did.
# =============================================================

resource "aws_db_subnet_group" "pipeline" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.project_name}-db-subnet"
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
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.pipeline.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "sun:04:00-sun:05:00"
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-final-snapshot" : null
  deletion_protection       = var.environment == "prod"
  copy_tags_to_snapshot     = true

  performance_insights_enabled = true

  tags = {
    Name = "${var.project_name}-mysql-source"
  }
}
