# Debezium CDC (unchanged role, new host)

This directory keeps the exact same connector contract as the original
project's `debezium/connectors/mysql-source.json` — same transform
(`ExtractNewRecordState`), same topic naming (`cdc.source_db.orders`,
`cdc.source_db.customers`), same `decimal.handling.mode=string` so the
downstream schema is unchanged. What changes is **where Kafka Connect runs**
and **what it points at**:

| | Original | lakehouse-databricks |
|---|---|---|
| Source DB | `mysql:8.0` container | Amazon RDS for MySQL (`terraform/rds.tf`) |
| Kafka broker | `kafka:29092` (Docker) | Amazon MSK (`terraform/msk.tf`) |
| Connect runtime | `debezium/connect:2.5` container | Same image, deployed on **MSK Connect** (managed) or a small self-managed Kafka Connect worker on ECS/Fargate |

## Option A — MSK Connect (recommended, fully managed)

1. Package the Debezium MySQL connector plugin as a custom plugin zip and
   upload it to S3.
2. Create an MSK Connect custom plugin + connector referencing
   `debezium/connectors/mysql-source.json` as the connector configuration,
   with `MSK_BOOTSTRAP_BROKERS` / `MYSQL_HOST` / `DEBEZIUM_MYSQL_PASSWORD`
   substituted from Secrets Manager via MSK Connect's secret provider.
3. MSK Connect handles worker scaling, TLS to the MSK cluster, and restarts —
   there is no `docker exec debezium ...` step anymore.

## Option B — self-managed Kafka Connect (closer to the original demo)

Run the same `debezium/connect:2.5` image (ECS task / EC2), with its
worker config pointed at the MSK bootstrap brokers over TLS:

```properties
bootstrap.servers=${MSK_BOOTSTRAP_BROKERS}
security.protocol=SSL
```

then register the connector exactly as before:

```bash
bash scripts/register_debezium.sh
```

## Verifying the CDC flow

```bash
# Confirm the connector is running
curl http://<connect-host>:8083/connectors/mysql-orders-source/status | python3 -m json.tool

# Insert a row on RDS MySQL and confirm it lands on the topic
mysql -h <rds-endpoint> -u pipeline_user -p source_db \
  -e "INSERT INTO orders (customer_id, amount) VALUES (1, 999.99);"
```

Use `kafka-console-consumer` against the MSK bootstrap brokers (or the AWS
console's MSK topic browser) in place of the original's AKHQ UI.
