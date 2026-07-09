# =============================================================
# AKHQ — Kafka UI, replaces the original docker-compose stack's AKHQ
# container. Runs as a single-task ECS/Fargate service in the same
# cluster as Debezium (aws_ecs_cluster.this, terraform/debezium.tf).
#
# Exposed the same way as RDS (terraform/rds.tf): a public subnet + a
# public IP + a security group scoped to var.admin_ip_cidr, instead of
# a private-only endpoint behind SSM port-forwarding. Find the current
# public IP (it's ephemeral — reassigned whenever the task restarts):
#
#   CLUSTER=$(terraform -chdir=terraform output -raw debezium_ecs_cluster)
#   SERVICE=$(terraform -chdir=terraform output -raw akhq_ecs_service)
#   TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" \
#     --query 'taskArns[0]' --output text)
#   ENI=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
#     --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text)
#   aws ec2 describe-network-interfaces --network-interface-ids "$ENI" \
#     --query 'NetworkInterfaces[0].Association.PublicIp' --output text
#
# Then open http://<public-ip>:8080
# =============================================================

resource "aws_cloudwatch_log_group" "akhq" {
  name              = "/ecs/${var.project_name}-akhq"
  retention_in_days = 14
}

resource "aws_iam_role" "ecs_task_akhq" {
  name = "${var.project_name}-ecs-task-akhq"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Grants only what's needed for ECS Exec / SSM port-forwarding into the
# AKHQ container — same shape as aws_iam_role_policy.ecs_exec for Debezium.
resource "aws_iam_role_policy" "akhq_ecs_exec" {
  name = "${var.project_name}-akhq-ecs-exec"
  role = aws_iam_role.ecs_task_akhq.id

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

resource "aws_ecs_task_definition" "akhq" {
  family                   = "${var.project_name}-akhq"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.akhq_task_cpu
  memory                   = var.akhq_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task_akhq.arn

  container_definitions = jsonencode([{
    name      = "akhq"
    image     = var.akhq_image
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    environment = [{
      name = "AKHQ_CONFIGURATION"
      value = <<-YAML
        akhq:
          connections:
            ${var.project_name}:
              properties:
                bootstrap.servers: "${aws_msk_cluster.this.bootstrap_brokers_tls}"
                security.protocol: SSL
              connect:
                - name: "debezium"
                  url: "http://debezium.${var.project_name}.internal:8083"
      YAML
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.akhq.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "akhq"
      }
    }
  }])
}

resource "aws_ecs_service" "akhq" {
  name                   = "${var.project_name}-akhq"
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.akhq.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.akhq.id]
    assign_public_ip = true
  }
}
