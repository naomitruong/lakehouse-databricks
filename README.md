# lakehouse-databricks

**Status: deployed.** `terraform apply` and `databricks bundle deploy` have
both run against a live AWS + Databricks workspace; `cdc_bronze_ingestion_job`
and `dbt_orchestration_job` have each completed successful runs with real
data flowing MySQL → Bronze → Silver → Gold.

A Databricks-native rebuild of [`e2e-data-engineer-cloud`](../e2e-data-engineer-cloud)'s
Medallion lakehouse (see that project's `LAKEHOUSE_V2_PLAN.txt`). Same demo
scenarios — CDC ingestion, Bronze/Silver/Gold, dbt transformations,
scheduled orchestration, BI serving — rebuilt on managed AWS + Databricks
services instead of a 20-container self-hosted stack.

```
MySQL (RDS)                                                Databricks SQL Warehouse
    |                                                       + BI tools (Tableau/Looker/Power BI)
    v  [Debezium CDC — binlog capture]                            ^
Amazon MSK topics: cdc.source_db.orders, cdc.source_db.customers  |
    |                                                              |
    v  [Databricks Structured Streaming, trigger(availableNow)]    |
Bronze (Delta, Unity Catalog: lakehouse.bronze.*)                  |
    |    append-only, all CDC ops preserved                        |
    v  [dbt-databricks incremental models — merge strategy]        |
Silver (Delta, lakehouse.silver.*)                                 |
    |    deduped, latest state, deletes removed                    |
    v  [dbt-databricks table models]                               |
Gold (Delta, lakehouse.gold.*) ------------------------------------+
    fact_orders, agg_daily_revenue

Orchestration: Databricks Workflows (databricks.yml + resources/*.yml)
Lineage/governance: Unity Catalog (automatic — no separate service)
Infra: Terraform (aws + databricks providers), AWS underlying cloud throughout
```

## Why rebuild it this way

The original stack proves the same concepts (CDC, medallion layering,
SQL-as-code transforms, lineage, federation) by wiring together open-source
components by hand: Debezium, Kafka, an Iceberg REST catalog on MinIO,
Trino, dbt-trino, Airflow, and OpenLineage/Marquez. This version keeps AWS
as the underlying cloud but swaps every one of those self-hosted pieces for
the managed Databricks/AWS service that plays the same architectural role —
so the *demo scenarios* (time travel, schema evolution, federation queries,
dbt lineage, data quality gates) still work, but there's no Docker Compose
stack to babysit.

## Component mapping

| Layer | Original (`e2e-data-engineer-cloud`) | This project (`lakehouse-databricks`) | Where |
|---|---|---|---|
| Source OLTP | `mysql:8.0` container, binlog enabled via `command:` flags | Amazon RDS for MySQL, binlog enabled via a custom DB parameter group | `terraform/rds.tf`, `scripts/init_mysql_cdc.sql` |
| CDC capture | Debezium (`debezium/connect:2.5` container) | Same Debezium connector config; deployed (this repo's default) as the same image on a self-managed Kafka Connect worker on ECS/Fargate, private subnet, Cloud Map DNS — MSK Connect documented as an alternative | `terraform/debezium.tf`, `debezium/connectors/mysql-source.json`, `debezium/README.md` |
| Kafka UI | AKHQ container | AKHQ on ECS/Fargate, public subnet with admin-IP allowlist | `terraform/akhq.tf` |
| Message bus | Self-hosted Kafka + Zookeeper | Amazon MSK — same topic names (`cdc.source_db.orders`, `cdc.source_db.customers`) | `terraform/msk.tf` |
| Object storage | MinIO (S3-compatible) | Amazon S3 (native) | `terraform/s3.tf` |
| Table format + catalog | Apache Iceberg + `tabulario/iceberg-rest` REST catalog | Delta Lake + Unity Catalog (catalog `lakehouse`, schemas `bronze`/`silver`/`gold`) | `terraform/unity_catalog.tf` |
| Bronze ingestion | Spark Structured Streaming (self-hosted Spark Master/Worker), one-shot `spark.read` re-scanning the topic from `earliest` every run | Databricks Structured Streaming job, `trigger(availableNow=True)` with a real checkpoint — incremental, no re-processing of history each run | `src/streaming/bronze_orders_stream.py`, `src/streaming/bronze_customers_stream.py` |
| Query / federation engine | Trino (`iceberg` + `postgresql` catalogs) | Databricks SQL Warehouse + Lakehouse Federation (foreign catalog over RDS for cross-source joins) | `terraform/databricks_compute.tf` (`databricks_sql_endpoint`) |
| Transformations | dbt-trino, Bronze (ephemeral) → Silver (incremental merge) → Gold (table) | dbt-databricks, **identical model SQL**, same layering and merge strategy | `dbt/models/**` |
| Data quality | dbt tests (`schema.yml`, custom test), replacing an earlier Great Expectations stub | Same dbt tests, unchanged — dbt tests are adapter-agnostic | `dbt/models/silver/schema.yml`, `dbt/tests/` |
| Orchestration | Airflow (`kafka_to_bronze_batch_dag`, `dbt_orchestration_dag`) as BashOperators shelling into containers | Databricks Workflows, defined as code via a Databricks Asset Bundle; native `dbt_task` and `notebook_task` types instead of `docker exec` | `databricks.yml`, `resources/cdc_bronze_job.yml`, `resources/dbt_orchestration_job.yml` |
| Lineage | OpenLineage emitted by `dbt-ol` + `spark.openlineage.*`, collected by Marquez (3 extra containers) | Unity Catalog automatic table/column lineage — no emitter, no extra service | `governance/unity_catalog_lineage.md` |
| Governance / classification | `governance/atlas_stub.py` (Apache Atlas stand-in) | Unity Catalog tags + grants + audit log system tables | `governance/unity_catalog_lineage.md` |
| ML tracking | Self-hosted MLflow container | Databricks Managed MLflow + Unity Catalog Model Registry (included in the workspace, no separate service) | *(not scaffolded here — enabled by default in any Databricks workspace)* |
| BI serving | `bi_dashboards/bi_dashboard.py` — queries Snowflake/Postgres star schema, pushes CSVs to Tableau/Looker/Power BI | Same script shape, queries `lakehouse.gold.*` Delta tables via `databricks-sql-connector` instead | `bi/bi_dashboard.py` |
| Infra as code | Terraform (`aws` provider only): VPC, EKS, RDS Postgres, S3, security groups | Terraform with **both** `aws` (VPC, MSK, RDS MySQL, S3, secrets) and `databricks` (Unity Catalog, SQL Warehouse, cluster policy, optionally the workspace itself) providers | `terraform/` |
| Compute platform | EKS + Helm chart (`helm/e2e-pipeline/`) for multi-cloud K8s deployment | No Kubernetes layer at all — Databricks *is* the compute platform (serverless SQL Warehouse + ephemeral job clusters) | — |
| Monitoring | Prometheus + Grafana + Elasticsearch (3 containers) | Databricks system tables (`system.billing`, `system.access.audit`, job run history) + Lakeview dashboards | *(not scaffolded here — see "Out of scope" below)* |
| Control-plane API | Custom .NET 8 gateway (`sample_dotnet_backend/`) fronting Airflow/Kafka/MinIO/MLflow | Databricks REST API / Jobs API / CLI / SDK — the platform ships its own control plane | — |

## Repository layout

```
lakehouse-databricks/
├── terraform/                # AWS (VPC, MSK, RDS, S3, secrets, ECS Fargate for Debezium+AKHQ) + Databricks (UC, SQL Warehouse, jobs infra)
├── debezium/                 # CDC connector config (same contract as the original), deployment notes
├── src/streaming/            # Bronze ingestion: Kafka(MSK) CDC -> Delta, via Databricks Structured Streaming
├── dbt/                      # dbt-databricks project: bronze (ephemeral) -> silver (incremental) -> gold (table)
├── databricks.yml            # Asset Bundle: orchestration-as-code (replaces airflow/dags/)
├── resources/                # Workflow (job) definitions included by databricks.yml
├── bi/                       # BI export script (Gold Delta tables -> Tableau/Looker/Power BI)
├── governance/               # Unity Catalog lineage/governance notes (replaces OpenLineage/Marquez/Atlas)
├── scripts/                  # MySQL CDC bootstrap SQL, Debezium connector registration
├── ARCHITECTURE.md           # Component/data-flow diagrams, mirrors the original's ARCHITECTURE.md
└── DEMO_SCENARIOS.md         # The 7 interview demos from LAKEHOUSE_V2_PLAN.txt, translated to Databricks
```

## Getting started

1. **Provision infra.**
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in secrets
   cp .env.example .env                                               # fill in secrets
   make tf-init
   make tf-plan
   make tf-apply
   ```
   By default this attaches to an **existing** Databricks workspace and UC
   metastore (`create_workspace = false`, `create_metastore = false`) — the
   common case for a demo account. Flip both to `true` in
   `terraform.tfvars` to bootstrap a brand-new E2 workspace from scratch.

2. **Bootstrap the CDC source.**
   ```bash
   mysql -h $(terraform -chdir=terraform output -raw mysql_endpoint) \
     -u pipeline_admin -p source_db < scripts/init_mysql_cdc.sql
   ```

3. **Register the Debezium connector** (see `debezium/README.md` for the
   MSK Connect vs. self-managed choice):
   ```bash
   make register-debezium
   ```

4. **Deploy the Databricks Workflows:**
   ```bash
   databricks configure   # or export DATABRICKS_HOST / DATABRICKS_TOKEN
   make bundle-deploy
   ```

5. **Run the demo.** See `DEMO_SCENARIOS.md` — insert a row into MySQL,
   watch it land in Bronze within one `cdc_bronze_ingestion_job` run (both
   jobs run on a 3-hour cron; trigger manually with
   `databricks bundle run cdc_bronze_ingestion_job -t dev` to skip the
   wait), then in Gold after `dbt_orchestration_job` runs.

## Out of scope (by design)

To keep this scaffold focused on the medallion/CDC/dbt/orchestration/BI
architecture the task asked for, a few original components were
deliberately not rebuilt 1:1:

- **The .NET 8 API gateway** — its job (a unified REST facade over
  Airflow/Kafka/MinIO/MLflow) is filled by the Databricks REST/Jobs API and
  CLI directly; there's no orchestrator-of-orchestrators left to front.
- **Prometheus/Grafana/Elasticsearch** — Databricks' system tables and
  Lakeview dashboards cover job/cluster/query observability natively.
  Wiring a Grafana dashboard on top of `system.*` tables is a natural
  follow-up but isn't included here.
- **Flink stateful streaming (Phase 3 of the original plan)** — was marked
  `[ ]` (not yet built) in the source project too; the equivalent on
  Databricks would be a Structured Streaming job with
  `flatMapGroupsWithState`/watermarks, left as a future addition.
