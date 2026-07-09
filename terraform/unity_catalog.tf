# =============================================================
# Unity Catalog — replaces the Iceberg REST catalog service.
#
# One storage credential + external location grants Unity Catalog
# access to the S3 bucket created in s3.tf; the `lakehouse` catalog
# and its bronze/silver/gold schemas are the direct equivalent of
# the `lakehouse.bronze` / `lakehouse.silver` / `lakehouse.gold`
# Iceberg namespaces the original Trino setup queried.
# =============================================================

# Databricks assigns one fixed external ID per metastore for AWS role trust
# (used in the sts:ExternalId condition below) — it is NOT something the
# caller can choose. Databricks ignores any external_id passed on
# databricks_storage_credential and always returns this same value for
# metastore 63de0ba0-55f5-4ba6-ba2b-083f8dce6a55, confirmed by creating a
# storage credential and reading it back (`terraform state show
# databricks_storage_credential.lakehouse`) — recreating the credential
# returned the identical ID. If this deployment ever moves to a different
# metastore, re-derive the value the same way (bootstrap the role/credential
# with any external_id, then read the real one back from state) before
# updating it here.
locals {
  uc_external_id = "ea52ba30-f337-4b3b-a2b5-ed0ccc51f169"
}

# IAM role Unity Catalog assumes (via Databricks' UC master role) to
# read/write the storage-root bucket.
data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  external_id    = local.uc_external_id
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = "${var.project_name}-uc-access-role"
}

resource "aws_iam_role" "uc_storage_credential" {
  name               = "${var.project_name}-uc-access-role"
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.this.json
}

data "databricks_aws_unity_catalog_policy" "this" {
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = aws_s3_bucket.unity_catalog_root.bucket
  role_name      = "${var.project_name}-uc-access-role"
}

resource "aws_iam_role_policy" "uc_storage_credential" {
  name   = "${var.project_name}-uc-access-policy"
  role   = aws_iam_role.uc_storage_credential.id
  policy = data.databricks_aws_unity_catalog_policy.this.json
}

data "aws_caller_identity" "current" {}

resource "databricks_storage_credential" "lakehouse" {
  name = "${var.project_name}-storage-credential"

  aws_iam_role {
    role_arn = aws_iam_role.uc_storage_credential.arn
  }

  comment = "Storage credential for the lakehouse-databricks bronze/silver/gold catalog (replaces Iceberg REST catalog + MinIO creds)."

  # The role's ARN is available as soon as the role exists, but the inline
  # policy granting S3 access is a separate resource — without this,
  # Terraform has no reason to wait for it before Databricks validates access.
  depends_on = [aws_iam_role_policy.uc_storage_credential]
}

# IAM policy and trust-policy changes take a few seconds to propagate across
# AWS even after the API call succeeds. Databricks validates S3 access
# immediately when creating the external location, so without this buffer it
# can hit a PERMISSION_DENIED race against the not-yet-propagated change.
# `triggers` forces this resource to be recreated (and re-sleep) whenever
# either policy's content changes, not just on first creation.
resource "time_sleep" "iam_propagation" {
  create_duration = "15s"

  triggers = {
    assume_role_policy = aws_iam_role.uc_storage_credential.assume_role_policy
    inline_policy      = aws_iam_role_policy.uc_storage_credential.policy
  }

  depends_on = [aws_iam_role_policy.uc_storage_credential]
}

resource "databricks_external_location" "lakehouse" {
  name            = "${var.project_name}-external-location"
  url             = "s3://${aws_s3_bucket.unity_catalog_root.bucket}/"
  credential_name = databricks_storage_credential.lakehouse.id
  comment         = "Storage root for the lakehouse catalog (replaces s3://lakehouse/ on MinIO)."

  depends_on = [time_sleep.iam_propagation]
}

# The Structured Streaming checkpoint bucket (terraform/s3.tf) is a separate
# bucket from the UC storage root, so it needs its own external location —
# without one, UC has no path covering s3://<checkpoints-bucket>/* and
# credential vending silently falls back to anonymous S3 access (403).
data "databricks_aws_unity_catalog_policy" "checkpoints" {
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = aws_s3_bucket.checkpoints.bucket
  role_name      = "${var.project_name}-uc-access-role"
}

resource "aws_iam_role_policy" "uc_storage_credential_checkpoints" {
  name   = "${var.project_name}-uc-access-policy-checkpoints"
  role   = aws_iam_role.uc_storage_credential.id
  policy = data.databricks_aws_unity_catalog_policy.checkpoints.json
}

resource "time_sleep" "iam_propagation_checkpoints" {
  create_duration = "15s"

  triggers = {
    inline_policy = aws_iam_role_policy.uc_storage_credential_checkpoints.policy
  }

  depends_on = [aws_iam_role_policy.uc_storage_credential_checkpoints]
}

resource "databricks_external_location" "checkpoints" {
  name            = "${var.project_name}-checkpoints-external-location"
  url             = "s3://${aws_s3_bucket.checkpoints.bucket}/"
  credential_name = databricks_storage_credential.lakehouse.id
  comment         = "Structured Streaming checkpoint location (replaces the spark_checkpoints Docker volume)."

  depends_on = [time_sleep.iam_propagation_checkpoints]
}

resource "databricks_grants" "checkpoints_external_location" {
  external_location = databricks_external_location.checkpoints.id

  grant {
    principal  = "account users"
    privileges = ["READ_FILES", "WRITE_FILES"]
  }
}

# --- Metastore (OPTIONAL — most workspaces already have one assigned
# per region; set create_metastore = true only when bootstrapping a
# brand-new region/account). ---
resource "databricks_metastore" "this" {
  provider     = databricks.account
  count        = var.create_metastore ? 1 : 0
  name         = var.uc_metastore_name
  storage_root = "s3://${aws_s3_bucket.unity_catalog_root.bucket}/metastore/"
  owner        = "account-admins"
  region       = var.aws_region
}

resource "databricks_metastore_assignment" "this" {
  provider     = databricks.account
  count        = var.create_metastore ? 1 : 0
  metastore_id = databricks_metastore.this[0].id
  workspace_id = var.create_workspace ? databricks_mws_workspaces.this[0].workspace_id : var.existing_workspace_id
}

# Attach a newly created workspace to an already-existing metastore. A fresh
# workspace has no metastore assigned, so without this the UC catalog below
# has nowhere to attach to. Not needed when create_workspace = false (the
# existing workspace already has a metastore assigned) or when
# create_metastore = true (the assignment above handles that case).
resource "databricks_metastore_assignment" "existing" {
  provider     = databricks.account
  count        = var.create_workspace && !var.create_metastore ? 1 : 0
  metastore_id = var.existing_metastore_id
  workspace_id = databricks_mws_workspaces.this[0].workspace_id
}

# --- Catalog + schemas (the actual bronze/silver/gold namespaces) ---
resource "databricks_catalog" "lakehouse" {
  name    = var.uc_catalog_name
  comment = "Medallion lakehouse catalog — replaces the `lakehouse` Iceberg catalog namespace."

  storage_root = databricks_external_location.lakehouse.url

  depends_on = [databricks_external_location.lakehouse]
}

resource "databricks_schema" "bronze" {
  catalog_name = databricks_catalog.lakehouse.name
  name         = "bronze"
  comment      = "Append-only raw CDC events, one Delta table per source table. Equivalent to iceberg.bronze.*"
}

resource "databricks_schema" "silver" {
  catalog_name = databricks_catalog.lakehouse.name
  name         = "silver"
  comment      = "Deduped latest-state Delta tables (dbt incremental merge). Equivalent to iceberg.silver.*"
}

resource "databricks_schema" "gold" {
  catalog_name = databricks_catalog.lakehouse.name
  name         = "gold"
  comment      = "Business-level facts/aggregates served to BI tools. Equivalent to iceberg.gold.*"
}

resource "databricks_grants" "lakehouse_catalog" {
  catalog = databricks_catalog.lakehouse.name

  grant {
    principal  = "account users"
    privileges = ["USE_CATALOG", "USE_SCHEMA"]
  }
}
