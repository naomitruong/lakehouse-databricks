# =============================================================
# Security Groups
# =============================================================

# MSK brokers — internal VPC only (Debezium/Kafka Connect + Databricks
# Structured Streaming jobs reach brokers over the private network)
resource "aws_security_group" "msk" {
  name        = "${var.project_name}-msk-sg"
  description = "Security group for the MSK (Kafka) cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Kafka plaintext/TLS broker ports"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Zookeeper (legacy client access, MSK-managed)"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-msk-sg"
  }
}

# RDS MySQL — reachable from MSK Connect / Debezium ENIs and from
# Databricks classic compute plane, both inside the VPC
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS MySQL (CDC source)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "MySQL from within the VPC (Debezium + Databricks)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "MySQL from admin public IP (DBeaver access)"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

# Debezium Kafka Connect (self-managed, e.g. on ECS/Fargate) — REST API
# reachable only from inside the VPC (operators use SSM port-forwarding
# or a bastion; nothing is exposed publicly)
resource "aws_security_group" "debezium" {
  name        = "${var.project_name}-debezium-sg"
  description = "Security group for the Debezium Kafka Connect worker"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Kafka Connect REST API"
    from_port   = 8083
    to_port     = 8083
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-debezium-sg"
  }
}

# AKHQ (Kafka UI) — like Debezium's REST API, reachable only from inside
# the VPC. Operators use `aws ecs execute-command` / SSM port-forwarding
# to reach the web UI from a local machine; nothing is exposed publicly.
resource "aws_security_group" "akhq" {
  name        = "${var.project_name}-akhq-sg"
  description = "Security group for the AKHQ Kafka UI"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "AKHQ web UI from within the VPC"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "AKHQ web UI from admin public IP (same pattern as RDS access)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-akhq-sg"
  }
}
