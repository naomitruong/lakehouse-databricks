# =============================================================
# General
# =============================================================
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "lakehouse-databricks"
}

# =============================================================
# Networking (same shape as the original EKS/RDS VPC — reused for
# MSK + RDS + Databricks classic-compute-plane connectivity)
# =============================================================
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (MSK brokers, RDS, Databricks classic compute)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (NAT Gateway)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# =============================================================
# Source database — Amazon RDS for MySQL (replaces self-hosted
# mysql:8.0 container; binlog enabled for Debezium CDC)
# =============================================================
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_username" {
  description = "MySQL master username"
  type        = string
  default     = "pipeline_admin"
}

variable "db_password" {
  description = "MySQL master password"
  type        = string
  sensitive   = true
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB for RDS"
  type        = number
  default     = 50
}

variable "db_multi_az" {
  description = "Enable Multi-AZ for RDS (recommended for prod)"
  type        = bool
  default     = false
}

variable "debezium_mysql_password" {
  description = "Password for the dedicated 'debezium' MySQL replication user"
  type        = string
  sensitive   = true
}

# =============================================================
# Amazon MSK — replaces self-hosted Zookeeper + Kafka containers
# =============================================================
variable "msk_kafka_version" {
  description = "Kafka version for the MSK cluster"
  type        = string
  default     = "3.6.0"
}

variable "msk_broker_instance_type" {
  description = "Instance type for MSK broker nodes"
  type        = string
  default     = "kafka.t3.small"
}

variable "msk_broker_count" {
  description = "Number of MSK broker nodes (must be a multiple of the number of AZs used)"
  type        = number
  default     = 2
}

variable "msk_ebs_volume_size" {
  description = "EBS volume size (GB) per MSK broker"
  type        = number
  default     = 100
}

# =============================================================
# Databricks workspace
# =============================================================
variable "create_workspace" {
  description = <<-EOT
    Whether Terraform should provision a brand-new Databricks E2 workspace
    (account-level: cross-account IAM role, root S3 bucket, network config,
    workspace). Set to false (default) to attach these resources to an
    existing workspace instead — the common case for a demo/POC where a
    workspace already exists in the account.
  EOT
  type        = bool
  default     = false
}

variable "databricks_account_id" {
  description = "Databricks account ID (only required when create_workspace = true)"
  type        = string
  default     = ""
}

variable "databricks_host" {
  description = "Existing Databricks workspace URL (only required when create_workspace = false)"
  type        = string
  default     = ""
}

variable "existing_workspace_id" {
  description = "Numeric workspace ID to attach a newly created metastore to (only used when create_metastore = true and create_workspace = false)"
  type        = string
  default     = ""
}

# =============================================================
# Unity Catalog
# =============================================================
variable "uc_metastore_name" {
  description = "Unity Catalog metastore name"
  type        = string
  default     = "lakehouse-metastore"
}

variable "uc_catalog_name" {
  description = "Unity Catalog catalog name (top-level namespace for bronze/silver/gold schemas)"
  type        = string
  default     = "lakehouse"
}

variable "create_metastore" {
  description = "Whether to create+assign a new UC metastore for this region, vs. reuse one already assigned to the workspace"
  type        = bool
  default     = false
}

# =============================================================
# Databricks compute
# =============================================================
variable "sql_warehouse_size" {
  description = "T-shirt size for the Databricks SQL Warehouse (Trino replacement)"
  type        = string
  default     = "Small"
}

variable "sql_warehouse_auto_stop_mins" {
  description = "Minutes of inactivity before the SQL Warehouse auto-suspends"
  type        = number
  default     = 10
}

variable "job_node_type" {
  description = "Node type for job clusters (Bronze streaming ingestion, dbt task)"
  type        = string
  default     = "m5d.large"
}

variable "spark_version" {
  description = "Databricks Runtime version for job clusters"
  type        = string
  default     = "15.4.x-scala2.12"
}
