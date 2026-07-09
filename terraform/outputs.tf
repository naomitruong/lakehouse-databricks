# =============================================================
# Outputs
# =============================================================

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "mysql_endpoint" {
  description = "RDS MySQL endpoint (CDC source — point Debezium's database.hostname here)"
  value       = aws_db_instance.mysql_source.address
}

output "msk_bootstrap_brokers_tls" {
  description = "MSK bootstrap brokers (TLS) — used by Debezium's producer config and the Databricks Structured Streaming job"
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
}

output "msk_cluster_arn" {
  description = "MSK cluster ARN"
  value       = aws_msk_cluster.this.arn
}

output "debezium_connect_url" {
  description = "Kafka Connect REST endpoint for the Debezium worker — set DEBEZIUM_CONNECT_URL to this before running scripts/register_debezium.sh"
  value       = "http://debezium.${var.project_name}.internal:8083"
}

output "debezium_ecs_cluster" {
  description = "ECS cluster name — use with `aws ecs list-tasks`/`aws ecs execute-command` to get a shell inside the VPC for debugging"
  value       = aws_ecs_cluster.this.name
}

output "akhq_ecs_service" {
  description = "ECS service name for the AKHQ Kafka UI — use with `aws ecs list-tasks --service-name <this>` then SSM port-forward to port 8080 (see terraform/akhq.tf for the full command)"
  value       = aws_ecs_service.akhq.name
}

output "unity_catalog_root_bucket" {
  description = "S3 bucket backing the Unity Catalog external location (replaces s3://lakehouse/ on MinIO)"
  value       = aws_s3_bucket.unity_catalog_root.bucket
}

output "checkpoints_bucket" {
  description = "S3 bucket for Structured Streaming checkpoints (replaces the spark_checkpoints Docker volume)"
  value       = aws_s3_bucket.checkpoints.bucket
}

output "databricks_sql_warehouse_id" {
  description = "SQL Warehouse ID — used by dbt's profiles.yml and the BI export script"
  value       = databricks_sql_endpoint.lakehouse.id
}

output "databricks_sql_warehouse_http_path" {
  description = "SQL Warehouse JDBC/ODBC HTTP path"
  value       = databricks_sql_endpoint.lakehouse.jdbc_url
}

output "unity_catalog_name" {
  description = "Unity Catalog catalog name (bronze/silver/gold schemas live under this)"
  value       = databricks_catalog.lakehouse.name
}

output "job_cluster_policy_id" {
  description = "Cluster policy ID applied to job clusters — set as resources/cdc_bronze_job.yml's new_cluster.policy_id so streaming tasks run on classic compute inside the VPC (required for MSK network access) instead of serverless"
  value       = databricks_cluster_policy.job_clusters.id
}

output "workspace_url" {
  description = "Databricks workspace URL (only populated when create_workspace = true)"
  value       = var.create_workspace ? databricks_mws_workspaces.this[0].workspace_url : var.databricks_host
}
