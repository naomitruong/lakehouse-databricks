terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Uncomment for remote state (recommended for teams)
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "lakehouse-databricks/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "lakehouse-databricks"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Account-level provider — only used when create_workspace = true, to stand up
# a brand-new E2 workspace (customer-managed VPC + cross-account role + root
# bucket). Most demo environments instead reuse an existing workspace, in
# which case only the workspace-level provider below is exercised.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}

# Workspace-level provider — used for Unity Catalog objects, SQL warehouses,
# jobs/workflows, secrets, and cluster policies. Authenticates against the
# workspace created below (if create_workspace = true) or an existing one
# (var.databricks_host / DATABRICKS_TOKEN env var).
provider "databricks" {
  host = var.create_workspace ? "https://${databricks_mws_workspaces.this[0].workspace_url}" : var.databricks_host
}
