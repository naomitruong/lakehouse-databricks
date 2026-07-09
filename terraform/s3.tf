# =============================================================
# S3 — replaces MinIO. One bucket is the Unity Catalog storage root
# (Delta table data for the bronze/silver/gold schemas), the other
# holds Structured Streaming checkpoints (replaces the
# `spark_checkpoints` Docker volume).
# =============================================================

resource "aws_s3_bucket" "unity_catalog_root" {
  bucket        = "${var.project_name}-uc-root-${var.environment}"
  force_destroy = var.environment != "prod"

  tags = {
    Name = "${var.project_name}-uc-root"
  }
}

resource "aws_s3_bucket_versioning" "unity_catalog_root" {
  bucket = aws_s3_bucket.unity_catalog_root.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "unity_catalog_root" {
  bucket = aws_s3_bucket.unity_catalog_root.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "unity_catalog_root" {
  bucket                  = aws_s3_bucket.unity_catalog_root.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "checkpoints" {
  bucket        = "${var.project_name}-checkpoints-${var.environment}"
  force_destroy = var.environment != "prod"

  tags = {
    Name = "${var.project_name}-checkpoints"
  }
}

resource "aws_s3_bucket_versioning" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    id     = "expire-old-checkpoint-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "checkpoints" {
  bucket                  = aws_s3_bucket.checkpoints.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
