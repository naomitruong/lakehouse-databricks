# Governance & Lineage: Unity Catalog

Replaces `governance/atlas_stub.py` and the OpenLineage/Marquez stack
(`marquez/`, the `dbt-ol` wrapper, `spark.openlineage.*` Spark configs in
the streaming jobs).

## What the original needed three separate systems for

| Concern | Original component |
|---|---|
| Column/table lineage graph | OpenLineage events emitted by `dbt-ol` + the Spark `OpenLineageSparkListener`, collected by Marquez |
| Data classification / PII tags | `governance/atlas_stub.py` (a stand-in for Apache Atlas) |
| Access control | Postgres/MySQL GRANTs + application-level checks |

## What Unity Catalog does instead

Unity Catalog captures all three natively, with zero extra services to run:

- **Lineage** — every read/write executed through a Unity Catalog table
  (dbt models, the Structured Streaming jobs in `src/streaming/`, ad hoc
  notebook queries) is automatically recorded. Catalog Explorer renders the
  same kind of DAG Marquez did — `bronze.orders` → `silver.orders_silver` →
  `gold.fact_orders` — down to the column level, with no `dbt-ol` wrapper
  and no `spark.openlineage.*` Spark configs required.
- **Tags & classification** — `databricks_catalog`/`databricks_schema` /
  table-level tags (e.g. `PII`, `SENSITIVE`) replace the tag definitions in
  `marquez/marquez.yml`. Apply with:
  ```sql
  ALTER TABLE lakehouse.silver.customers_silver
    SET TAGS ('classification' = 'PII');
  ```
- **Access control** — `databricks_grants` (see `terraform/unity_catalog.tf`)
  replaces per-database GRANTs; privileges are catalog/schema/table-scoped
  and enforced consistently whether the query comes from a notebook, a dbt
  run, or a BI tool through the SQL Warehouse.
- **Audit** — every action against a Unity Catalog object is logged to the
  workspace's audit log system tables (`system.access.audit`), replacing
  the need for a bespoke audit trail.

## Viewing lineage for this project

After the `dbt_orchestration_job` workflow has run at least once:

1. Open **Catalog Explorer** → `lakehouse` catalog → `gold` → `fact_orders`.
2. Click the **Lineage** tab — you'll see `silver.orders_silver` and
   `silver.customers_silver` as upstream inputs, and (one hop further back)
   `bronze.orders` / `bronze.customers` as their sources.
3. Column-level lineage shows, e.g., `fact_orders.customer_name` tracing
   back to `customers_silver.customer_name` → `bronze.customers.customer_name`.

This is the direct equivalent of Demo 6 in the original's
`LAKEHOUSE_V2_PLAN.txt` ("dbt lineage + docs"), minus the Marquez UI and
the `dbt docs serve` step being a separate concern from lineage — Catalog
Explorer shows both in one place.
