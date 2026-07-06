# Demo Scenarios

Direct translations of the 7 demos in the original project's
`LAKEHOUSE_V2_PLAN.txt`. Same story, same order — only the tool names and
commands change.

## Demo 1 — End-to-end CDC flow (5 min)

```bash
mysql -h $(terraform -chdir=terraform output -raw mysql_endpoint) \
  -u pipeline_user -p source_db \
  -e "INSERT INTO orders (customer_id, amount) VALUES (1, 999.99);"
```

- Confirm the event landed on MSK: browse the `cdc.source_db.orders` topic
  in the AWS MSK console (or `kafka-console-consumer.sh` against the
  bootstrap brokers) — this replaces the original's AKHQ UI.
- Trigger (or wait ≤10 min for) `cdc_bronze_ingestion_job`:
  ```bash
  databricks bundle run cdc_bronze_ingestion_job -t dev
  ```
  Then, in a Databricks SQL editor / `databricks-sql-cli`:
  ```sql
  SELECT * FROM lakehouse.bronze.orders
  ORDER BY _ingested_at DESC LIMIT 1;
  ```
- Trigger `dbt_orchestration_job`, then:
  ```sql
  SELECT * FROM lakehouse.gold.fact_orders
  WHERE order_id = <new_id>;
  ```

## Demo 2 — Delta Time Travel (replaces Iceberg time travel)

```sql
SELECT * FROM lakehouse.bronze.orders
TIMESTAMP AS OF '2024-01-15 12:00:00';

SELECT * FROM lakehouse.bronze.orders VERSION AS OF 3;

DESCRIBE HISTORY lakehouse.bronze.orders;
```

`DESCRIBE HISTORY` is the Delta equivalent of querying
`iceberg."bronze"."orders$snapshots"` — it lists every commit (operation,
timestamp, operation metrics) instead of Iceberg's metadata table syntax.

## Demo 3 — Schema Evolution (zero downtime, no data rewrite)

```sql
ALTER TABLE lakehouse.bronze.orders ADD COLUMN discount DECIMAL(5,2);

SELECT order_id, amount, discount FROM lakehouse.bronze.orders LIMIT 5;
-- Old rows return NULL for discount — no file rewrite, no downtime,
-- identical guarantee to the Iceberg version of this demo.
```

If the write comes from the Structured Streaming job instead of a manual
`ALTER TABLE`, enable `.option("mergeSchema", "true")` on the writer, or
`spark.databricks.delta.schema.autoMerge.enabled = true` at the session
level — Delta's equivalent of Iceberg's implicit schema evolution.

## Demo 4 — Partition Evolution

Delta doesn't support Iceberg's hidden partitioning / in-place partition
evolution (`ADD PARTITION FIELD` on a live table). The idiomatic Delta
equivalent is **liquid clustering**, which gets you the same practical
outcome — changing the physical data layout without a full table
rewrite or coordinating a migration window:

```sql
ALTER TABLE lakehouse.silver.orders_silver
  CLUSTER BY (customer_id, order_date);

OPTIMIZE lakehouse.silver.orders_silver;
```

Unlike Iceberg's partition spec evolution (old files keep their old
partitioning, new files use the new spec), liquid clustering
incrementally reclusters data during `OPTIMIZE` — call out this
difference explicitly if asked, since it's a genuine trade-off, not just
a renamed feature.

## Demo 5 — Federation Query (Trino cross-source JOIN → Lakehouse Federation)

Register RDS as a foreign catalog once (see `terraform/unity_catalog.tf`
for where to add a `databricks_connection` + `databricks_catalog` of type
`postgresql`/`mysql`), then:

```sql
SELECT
    g.order_id,
    g.amount              AS lakehouse_amount,
    r.amount               AS source_amount,
    g.amount - r.amount    AS discrepancy
FROM lakehouse.gold.fact_orders g
JOIN rds_source_db.source_db.orders r ON g.order_id = r.order_id
WHERE ABS(g.amount - r.amount) > 0.01;
```

Same cross-engine join Trino's `postgresql` catalog demonstrated — now a
single Databricks SQL query with no second query engine to run.

## Demo 6 — dbt lineage + docs

```bash
cd dbt && dbt docs generate && dbt docs serve --port 8087
```

For the lineage graph itself, skip the Marquez UI entirely — open
**Catalog Explorer → lakehouse → gold → fact_orders → Lineage** in the
Databricks workspace. See `governance/unity_catalog_lineage.md` for detail
on why this replaces OpenLineage/Marquez outright rather than just moving it.

## Demo 7 — Data quality gates

```bash
cd dbt && dbt test --select silver
```

Same `unique`, `not_null`, `relationships`, and `dbt_utils.expression_is_true`
tests as the original (`dbt/models/silver/schema.yml`) — dbt tests are
adapter-agnostic, so nothing about the tests themselves changed, only the
warehouse they run against.
