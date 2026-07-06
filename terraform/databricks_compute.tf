# =============================================================
# Databricks compute — replaces the Spark Master/Worker containers
# (job clusters, ephemeral, spun up per Workflow run) and Trino
# (the SQL Warehouse, used by dbt and BI tools for interactive query).
# =============================================================

resource "databricks_sql_endpoint" "lakehouse" {
  name              = "${var.project_name}-warehouse"
  cluster_size      = var.sql_warehouse_size
  auto_stop_mins    = var.sql_warehouse_auto_stop_mins
  max_num_clusters  = 1
  enable_serverless_compute = true

  tags {
    custom_tags {
      key   = "project"
      value = var.project_name
    }
  }
}

# Cluster policy applied to job clusters used by the Bronze streaming
# ingestion task and the dbt task, capping instance type/size so ad hoc
# workflow edits can't silently balloon cost — the Databricks analogue
# of the original docker-compose CPU/memory limits on spark-worker.
resource "databricks_cluster_policy" "job_clusters" {
  name = "${var.project_name}-job-cluster-policy"

  definition = jsonencode({
    "spark_version" : {
      "type" : "fixed",
      "value" : var.spark_version
    },
    "node_type_id" : {
      "type" : "allowlist",
      "values" : [var.job_node_type]
    },
    "autoscale.max_workers" : {
      "type" : "range",
      "maxValue" : 4
    },
    "custom_tags.project" : {
      "type" : "fixed",
      "value" : var.project_name
    }
  })
}
