# =============================================================
# Amazon MSK — replaces the self-hosted Zookeeper + Kafka containers.
#
# Debezium still writes CDC events to Kafka topics named exactly as
# before (cdc.source_db.orders, cdc.source_db.customers); only the
# broker is now a managed AWS service instead of a Docker container.
# =============================================================

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/msk/${var.project_name}"
  retention_in_days = 14
}

resource "aws_msk_configuration" "this" {
  name              = "${var.project_name}-msk-config"
  kafka_versions    = [var.msk_kafka_version]
  server_properties = <<-PROPERTIES
    auto.create.topics.enable=false
    default.replication.factor=2
    min.insync.replicas=1
    num.partitions=3
  PROPERTIES
}

resource "aws_msk_cluster" "this" {
  cluster_name           = "${var.project_name}-msk"
  kafka_version           = var.msk_kafka_version
  number_of_broker_nodes  = var.msk_broker_count

  broker_node_group_info {
    instance_type   = var.msk_broker_instance_type
    client_subnets  = aws_subnet.private[*].id
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.msk_ebs_volume_size
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = true
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = {
    Name = "${var.project_name}-msk"
  }
}
