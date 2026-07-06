# =============================================================
# Unity Catalog — replaces the Iceberg REST catalog service.
#
# One storage credential + external location grants Unity Catalog
# access to the S3 bucket created in s3.tf; the `lakehouse` catalog
# and its bronze/silver/gold schemas are the direct equivalent of
# the `lakehouse.bronze` / `lakehouse.silver` / `lakehouse.gold`
# Iceberg namespaces the original Trino setup queried.
# =============================================================

resource "random_uuid" "uc_external_id" {}

# IAM role Unity Catalog assumes (via Databricks' UC master role) to
# read/write the storage-root bucket. The external_id above breaks the
# create-role -> create-credential -> update-role-trust circular
# dependency that a Databricks-generated external ID would otherwise
# require a second `terraform apply` to resolve.
data "databricks_aws_unity_catalog_assume_role_policy" "this" {
  external_id = random_uuid.uc_external_id.result
  account_id  = var.databricks_account_id
  role_name   = "${var.project_name}-uc-access-role"
}

resource "aws_iam_role" "uc_storage_credential" {
  name                 = "${var.project_name}-uc-access-role"
  assume_role_policy   = data.databricks_aws_unity_catalog_assume_role_policy.this.json
  managed_policy_arns  = []
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
}

resource "databricks_external_location" "lakehouse" {
  name            = "${var.project_name}-external-location"
  url             = "s3://${aws_s3_bucket.unity_catalog_root.bucket}/"
  credential_name = databricks_storage_credential.lakehouse.id
  comment         = "Storage root for the lakehouse catalog (replaces s3://lakehouse/ on MinIO)."
}

# --- Metastore (OPTIONAL — most workspaces already have one assigned
# per region; set create_metastore = true only when bootstrapping a
# brand-new region/account). ---
resource "databricks_metastore" "this" {
  provider      = databricks.account
  count         = var.create_metastore ? 1 : 0
  name          = var.uc_metastore_name
  storage_root  = "s3://${aws_s3_bucket.unity_catalog_root.bucket}/metastore/"
  owner         = "account-admins"
  region        = var.aws_region
}

resource "databricks_metastore_assignment" "this" {
  provider             = databricks.account
  count                = var.create_metastore ? 1 : 0
  metastore_id         = databricks_metastore.this[0].id
  workspace_id         = var.create_workspace ? databricks_mws_workspaces.this[0].workspace_id : var.existing_workspace_id
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
