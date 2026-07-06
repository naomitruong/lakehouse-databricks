# =============================================================
# Databricks E2 workspace (account-level) — OPTIONAL.
#
# Only created when var.create_workspace = true. This mirrors the
# original project's `deploy_to_eks` toggle: most environments point
# this stack at an already-existing workspace (var.databricks_host)
# and skip straight to the Unity Catalog / jobs resources below.
# Flip this on to stand up a fresh customer-managed-VPC workspace
# from scratch, wired into the VPC created in networking.tf.
# =============================================================

resource "aws_s3_bucket" "workspace_root" {
  count  = var.create_workspace ? 1 : 0
  bucket = "${var.project_name}-workspace-root-${var.environment}"

  tags = {
    Name = "${var.project_name}-workspace-root"
  }
}

resource "aws_s3_bucket_policy" "workspace_root" {
  count  = var.create_workspace ? 1 : 0
  bucket = aws_s3_bucket.workspace_root[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DatabricksRootBucketAccess"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::414351767826:root" } # Databricks control-plane account
      Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = [
        aws_s3_bucket.workspace_root[0].arn,
        "${aws_s3_bucket.workspace_root[0].arn}/*",
      ]
    }]
  })
}

# Cross-account IAM role Databricks assumes to manage compute-plane EC2/VPC
# resources on your behalf (equivalent in spirit to the original eks.tf
# cluster/node IAM roles, but for the Databricks control plane instead).
resource "aws_iam_role" "databricks_cross_account" {
  count = var.create_workspace ? 1 : 0
  name  = "${var.project_name}-databricks-cross-account"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::414351767826:root" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.databricks_account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "databricks_cross_account" {
  count = var.create_workspace ? 1 : 0
  name  = "${var.project_name}-databricks-cross-account-policy"
  role  = aws_iam_role.databricks_cross_account[0].id

  # Minimal policy shape per Databricks docs (ec2, vpc management for the
  # classic compute plane). Trim/expand for your security posture.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:*", "iam:CreateServiceLinkedRole"]
      Resource = "*"
    }]
  })
}

resource "databricks_mws_credentials" "this" {
  provider         = databricks.account
  count            = var.create_workspace ? 1 : 0
  account_id       = var.databricks_account_id
  role_arn         = aws_iam_role.databricks_cross_account[0].arn
  credentials_name = "${var.project_name}-creds"
}

resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.account
  count                      = var.create_workspace ? 1 : 0
  account_id                 = var.databricks_account_id
  bucket_name                = aws_s3_bucket.workspace_root[0].bucket
  storage_configuration_name = "${var.project_name}-storage"
}

resource "databricks_mws_networks" "this" {
  provider           = databricks.account
  count              = var.create_workspace ? 1 : 0
  account_id         = var.databricks_account_id
  network_name       = "${var.project_name}-network"
  vpc_id             = aws_vpc.main.id
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.databricks_compute[0].id]
}

resource "aws_security_group" "databricks_compute" {
  count       = var.create_workspace ? 1 : 0
  name        = "${var.project_name}-databricks-compute-sg"
  description = "Security group for the Databricks classic compute plane"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Intra-VPC compute-plane traffic"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-databricks-compute-sg"
  }
}

resource "databricks_mws_workspaces" "this" {
  provider        = databricks.account
  count           = var.create_workspace ? 1 : 0
  account_id      = var.databricks_account_id
  workspace_name  = var.project_name
  aws_region      = var.aws_region

  credentials_id           = databricks_mws_credentials.this[0].credentials_id
  storage_configuration_id = databricks_mws_storage_configurations.this[0].storage_configuration_id
  network_id               = databricks_mws_networks.this[0].network_id
}
