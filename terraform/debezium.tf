# =============================================================
# Debezium Kafka Connect worker — replaces the self-managed
# `debezium/connect:2.5` container from the original docker-compose
# stack. Runs as a single-task ECS/Fargate service inside the private
# subnets, reachable only from inside the VPC (aws_security_group.debezium,
# defined in security.tf, already scopes port 8083 to var.vpc_cidr).
#
# The worker itself only needs to reach MSK — MySQL credentials are only
# needed by the connector config registered afterwards via REST
# (see debezium/connectors/mysql-source.json + scripts/register_debezium.sh),
# not by the Connect worker process.
# =============================================================

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-ecs"
}

resource "aws_cloudwatch_log_group" "debezium" {
  name              = "/ecs/${var.project_name}-debezium"
  retention_in_days = 14
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Task role (distinct from the execution role above) — grants only what's
# needed for ECS Exec, so `aws ecs execute-command` can open an interactive
# shell inside the running container. This doubles as the in-VPC debug host
# (nc, mysql client, etc.) without standing up a separate bastion.
resource "aws_iam_role" "ecs_task_debezium" {
  name = "${var.project_name}-ecs-task-debezium"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_exec" {
  name = "${var.project_name}-ecs-exec"
  role = aws_iam_role.ecs_task_debezium.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

# Private DNS namespace so the Kafka Connect REST API has a stable address
# (debezium.<project_name>.internal) instead of an ephemeral task IP.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = "${var.project_name}.internal"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "debezium" {
  name = "debezium"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

resource "aws_ecs_task_definition" "debezium" {
  family                   = "${var.project_name}-debezium"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.debezium_task_cpu
  memory                   = var.debezium_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_debezium.arn

  container_definitions = jsonencode([{
    name      = "debezium"
    image     = var.debezium_connect_image
    essential = true

    portMappings = [{
      containerPort = 8083
      protocol      = "tcp"
    }]

    environment = [
      { name = "BOOTSTRAP_SERVERS", value = aws_msk_cluster.this.bootstrap_brokers_tls },
      { name = "GROUP_ID", value = "${var.project_name}-connect" },
      { name = "CONFIG_STORAGE_TOPIC", value = "_connect-configs" },
      { name = "OFFSET_STORAGE_TOPIC", value = "_connect-offsets" },
      { name = "STATUS_STORAGE_TOPIC", value = "_connect-status" },
      { name = "CONNECT_SECURITY_PROTOCOL", value = "SSL" },
      { name = "CONNECT_PRODUCER_SECURITY_PROTOCOL", value = "SSL" },
      { name = "CONNECT_CONSUMER_SECURITY_PROTOCOL", value = "SSL" },
      { name = "CONNECT_REST_ADVERTISED_HOST_NAME", value = "debezium.${var.project_name}.internal" },
      { name = "CONNECT_KEY_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_VALUE_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE", value = "false" },
      { name = "CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE", value = "false" },
      # msk_broker_count defaults to 2, below Connect's default replication factor of 3
      { name = "CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR", value = "2" },
      { name = "CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR", value = "2" },
      { name = "CONNECT_STATUS_STORAGE_REPLICATION_FACTOR", value = "2" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.debezium.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "debezium"
      }
    }
  }])
}

resource "aws_ecs_service" "debezium" {
  name                   = "${var.project_name}-debezium"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.debezium.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.debezium.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.debezium.arn
  }
}

# =============================================================
# One-time MySQL bootstrap (seed schema/data + 'debezium' CDC user)
#
# RDS has no public endpoint, so `terraform apply` can't run
# scripts/init_mysql_cdc.sql directly. Instead this runs the official
# mysql:8.0 image as a throwaway ECS/Fargate task in the private subnets —
# same pattern as the Debezium worker above — and waits for it to finish.
# Re-runs only when the SQL file changes or the DB instance is replaced.
# =============================================================

resource "aws_ecs_task_definition" "mysql_init" {
  family                   = "${var.project_name}-mysql-init"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "mysql-client"
    image     = "mysql:8.0"
    essential = true
    command   = ["mysql", "--version"]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.debezium.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "mysql-init"
      }
    }
  }])
}

resource "null_resource" "mysql_init" {
  triggers = {
    sql_hash       = filemd5("${path.module}/../scripts/init_mysql_cdc.sql")
    db_instance_id = aws_db_instance.mysql_source.id
  }

  provisioner "local-exec" {
    command = "python3 ${path.module}/scripts/run_mysql_init.py"

    environment = {
      AWS_REGION              = var.aws_region
      ECS_CLUSTER             = aws_ecs_cluster.this.name
      TASK_DEFINITION         = aws_ecs_task_definition.mysql_init.family
      SUBNET_IDS              = join(",", aws_subnet.private[*].id)
      SECURITY_GROUP_ID       = aws_security_group.debezium.id
      LOG_GROUP               = aws_cloudwatch_log_group.debezium.name
      MYSQL_HOST              = aws_db_instance.mysql_source.address
      MYSQL_ADMIN_USER        = var.db_username
      MYSQL_ADMIN_PASSWORD    = var.db_password
      DEBEZIUM_MYSQL_PASSWORD = var.debezium_mysql_password
      SQL_FILE                = "${path.module}/../scripts/init_mysql_cdc.sql"
    }
  }
}
