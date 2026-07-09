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

## Option B — self-managed Kafka Connect (implemented, this repo's default)

Provisioned by `terraform/debezium.tf`: the `debezium/connect:2.5` image runs as a
single-task ECS/Fargate service in the private subnets, with a Cloud Map DNS name
(`debezium.<project_name>.internal:8083`) so the REST API has a stable address instead
of an ephemeral task IP. No MySQL credentials are baked into the worker — only the
connector config registered below needs them.

Register the connector once the service is up:

```bash
export DEBEZIUM_CONNECT_URL=$(terraform -chdir=terraform output -raw debezium_connect_url)
bash scripts/register_debezium.sh
```

This must be run from inside the VPC (the REST API is private-only) — see "Debugging
from inside the VPC" below.

## Debugging from inside the VPC

The Debezium ECS task has `enable_execute_command = true`, so it doubles as the in-VPC
debug host — no separate bastion needed:

```bash
CLUSTER=$(terraform -chdir=terraform output -raw debezium_ecs_cluster)
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[0]' --output text)
aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" \
  --container debezium --interactive --command "/bin/bash"

# from inside the shell:
nc -zvw5 <rds-endpoint> 3306
```

## Verifying the CDC flow

```bash
# Confirm the connector is running
curl "$DEBEZIUM_CONNECT_URL/connectors/mysql-orders-source/status" | python3 -m json.tool

# Insert a row on RDS MySQL and confirm it lands on the topic
mysql -h <rds-endpoint> -u pipeline_user -p source_db \
  -e "INSERT INTO orders (customer_id, amount) VALUES (1, 999.99);"
```

Use `kafka-console-consumer` against the MSK bootstrap brokers (or the AWS
console's MSK topic browser) for a quick check from inside the Debezium
task's shell. For a proper UI, `terraform/akhq.tf` provisions the same AKHQ
container as the original docker-compose stack, as a private ECS/Fargate
service — see that file's header comment for the SSM port-forwarding
command to reach it at `http://localhost:8080`.
