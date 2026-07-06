# =============================================================
# Secrets — credentials referenced by the Bronze streaming job and
# the Debezium connector config. AWS Secrets Manager holds the
# source of truth; a Databricks-backed secret scope exposes the
# same values to notebooks/jobs via dbutils.secrets.get(...),
# replacing the plaintext .env file the Docker Compose stack used.
# =============================================================

resource "aws_secretsmanager_secret" "mysql_debezium" {
  name = "${var.project_name}/mysql-debezium-credentials"
}

resource "aws_secretsmanager_secret_version" "mysql_debezium" {
  secret_id = aws_secretsmanager_secret.mysql_debezium.id
  secret_string = jsonencode({
    username = "debezium"
    password = var.debezium_mysql_password
    host     = aws_db_instance.mysql_source.address
    port     = 3306
  })
}

resource "databricks_secret_scope" "lakehouse" {
  name = "lakehouse-databricks"
}

resource "databricks_secret" "mysql_debezium_password" {
  key          = "mysql-debezium-password"
  string_value = var.debezium_mysql_password
  scope        = databricks_secret_scope.lakehouse.name
}

resource "databricks_secret" "msk_bootstrap_brokers" {
  key          = "msk-bootstrap-brokers"
  string_value = aws_msk_cluster.this.bootstrap_brokers_tls
  scope        = databricks_secret_scope.lakehouse.name
}
