# Databricks notebook source
# CDC Kafka (MSK) -> Delta Bronze, orders.
#
# Replaces spark/spark_streaming_job.py from the original project. Two
# deliberate changes versus the original, both enabled by running on
# Databricks instead of self-hosted Spark:
#
#   1. True Structured Streaming with trigger(availableNow=True) and a
#      checkpoint on S3, instead of a stateless `spark.read` batch that
#      re-scanned the topic from `earliest` on every 10-minute Airflow
#      run (and therefore re-appended every historical CDC event into
#      Bronze each time it ran). Checkpointing makes each run pick up
#      only new offsets — Bronze stays append-only *and* non-duplicated.
#   2. Unity Catalog three-level names (catalog.bronze.orders) instead
#      of the Iceberg REST catalog's `lakehouse.bronze.orders`.
#
# Scheduled as a task in the Databricks Workflow defined in
# resources/lakehouse_orchestration_job.yml (replaces
# airflow/dags/kafka_to_bronze_batch_dag.py).

from pyspark.sql import SparkSession
from pyspark.sql.functions import col, current_timestamp, from_json, get_json_object, to_timestamp
from pyspark.sql.types import DecimalType, IntegerType, LongType, StringType, StructField, StructType

dbutils.widgets.text("catalog", "lakehouse")
dbutils.widgets.text("checkpoint_root", "s3://REPLACE_WITH_CHECKPOINTS_BUCKET/bronze")
CATALOG = dbutils.widgets.get("catalog")
CHECKPOINT_ROOT = dbutils.widgets.get("checkpoint_root")

KAFKA_TOPIC = "cdc.source_db.orders"
BRONZE_TABLE = f"{CATALOG}.bronze.orders"
CHECKPOINT_LOCATION = f"{CHECKPOINT_ROOT}/orders"

MSK_BOOTSTRAP_BROKERS = dbutils.secrets.get(scope="lakehouse-databricks", key="msk-bootstrap-brokers")

CDC_SCHEMA = StructType(
    [
        StructField("order_id", IntegerType(), True),
        StructField("customer_id", IntegerType(), True),
        StructField("amount", StringType(), True),  # decimal.handling.mode=string
        StructField("order_date", StringType(), True),  # ZonedTimestamp as ISO-8601 string
        StructField("__deleted", StringType(), True),
        StructField("__op", StringType(), True),  # c/u/d/r
        StructField("__ts_ms", LongType(), True),
        StructField("__db", StringType(), True),
        StructField("__table", StringType(), True),
    ]
)

spark = SparkSession.builder.appName("CDC_Kafka_to_Delta_Bronze_Orders").getOrCreate()

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.bronze")
spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {BRONZE_TABLE} (
        order_id     INT,
        customer_id  INT,
        amount       DECIMAL(10, 2),
        order_date   TIMESTAMP,
        _cdc_deleted BOOLEAN,
        _cdc_op      STRING,
        _cdc_ts_ms   BIGINT,
        _ingested_at TIMESTAMP
    )
    USING DELTA
    PARTITIONED BY (days(order_date))
    """
)

df_raw = (
    spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers", MSK_BOOTSTRAP_BROKERS)
    .option("kafka.security.protocol", "SSL")
    .option("subscribe", KAFKA_TOPIC)
    .option("startingOffsets", "earliest")
    .option("failOnDataLoss", "false")
    .load()
)

df = (
    df_raw.select(
        from_json(
            get_json_object(col("value").cast("string"), "$.payload"),
            CDC_SCHEMA,
        ).alias("d")
    )
    .select("d.*")
    .filter(col("order_id").isNotNull())
    .select(
        col("order_id").cast(IntegerType()),
        col("customer_id").cast(IntegerType()),
        col("amount").cast(DecimalType(10, 2)),
        to_timestamp(col("order_date")).alias("order_date"),
        (col("__deleted") == "true").alias("_cdc_deleted"),
        col("__op").alias("_cdc_op"),
        col("__ts_ms").alias("_cdc_ts_ms"),
        current_timestamp().alias("_ingested_at"),
    )
)

query = (
    df.writeStream.format("delta")
    .option("checkpointLocation", CHECKPOINT_LOCATION)
    .outputMode("append")
    .trigger(availableNow=True)
    .toTable(BRONZE_TABLE)
)
query.awaitTermination()

print(f"Bronze orders ingestion complete -> {BRONZE_TABLE}")
