# Databricks notebook source
# CDC Kafka (MSK) -> Delta Bronze, customers.
# Replaces spark/spark_streaming_customers_job.py — see bronze_orders_stream.py
# for the full explanation of what changed vs. the original and why.

from pyspark.sql import SparkSession
from pyspark.sql.functions import col, current_timestamp, from_json, get_json_object, to_timestamp
from pyspark.sql.types import IntegerType, LongType, StringType, StructField, StructType

dbutils.widgets.text("catalog", "lakehouse")
dbutils.widgets.text("checkpoint_root", "s3://REPLACE_WITH_CHECKPOINTS_BUCKET/bronze")
CATALOG = dbutils.widgets.get("catalog")
CHECKPOINT_ROOT = dbutils.widgets.get("checkpoint_root")

KAFKA_TOPIC = "cdc.source_db.customers"
BRONZE_TABLE = f"{CATALOG}.bronze.customers"
CHECKPOINT_LOCATION = f"{CHECKPOINT_ROOT}/customers"

MSK_BOOTSTRAP_BROKERS = dbutils.secrets.get(scope="lakehouse-databricks", key="msk-bootstrap-brokers")

CDC_SCHEMA = StructType(
    [
        StructField("customer_id", IntegerType(), True),
        StructField("customer_name", StringType(), True),
        StructField("join_date", StringType(), True),
        StructField("__op", StringType(), True),
        StructField("__ts_ms", LongType(), True),
        StructField("__db", StringType(), True),
        StructField("__table", StringType(), True),
    ]
)

spark = SparkSession.builder.appName("CDC_Kafka_to_Delta_Bronze_Customers").getOrCreate()

spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.bronze")
spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {BRONZE_TABLE} (
        customer_id   INT,
        customer_name STRING,
        join_date     TIMESTAMP,
        _cdc_op       STRING,
        _cdc_ts_ms    BIGINT,
        _ingested_at  TIMESTAMP
    )
    USING DELTA
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
    .filter(col("customer_id").isNotNull())
    .select(
        col("customer_id").cast(IntegerType()),
        col("customer_name"),
        to_timestamp(col("join_date")).alias("join_date"),
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

print(f"Bronze customers ingestion complete -> {BRONZE_TABLE}")
