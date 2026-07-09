#!/usr/bin/env python3
# Invoked by terraform/debezium.tf's null_resource.mysql_init (local-exec).
#
# RDS has no public endpoint, so `terraform apply` can't run scripts/init_mysql_cdc.sql
# directly against it. Instead this launches the official mysql:8.0 image as a
# throwaway ECS/Fargate task inside the private subnets (same pattern as the
# Debezium worker) to create the seed schema/data and the 'debezium' CDC user,
# then waits for it to finish and surfaces failures back to `terraform apply`.

import json
import os
import subprocess
import sys
import time


def env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"missing required env var: {name}")
    return value


def aws_cli(region, *args):
    return subprocess.run(
        ["aws", "--region", region, *args], capture_output=True, text=True
    )


def main():
    region = env("AWS_REGION")
    cluster = env("ECS_CLUSTER")
    task_definition = env("TASK_DEFINITION")
    subnets = env("SUBNET_IDS").split(",")
    security_group = env("SECURITY_GROUP_ID")
    log_group = env("LOG_GROUP")
    mysql_host = env("MYSQL_HOST")
    admin_user = env("MYSQL_ADMIN_USER")
    admin_password = env("MYSQL_ADMIN_PASSWORD")
    debezium_password = env("DEBEZIUM_MYSQL_PASSWORD")
    sql_file = env("SQL_FILE")

    with open(sql_file) as f:
        sql = f.read().replace("${DEBEZIUM_MYSQL_PASSWORD}", debezium_password)

    overrides = {
        "containerOverrides": [
            {
                "name": "mysql-client",
                "command": [
                    "sh",
                    "-c",
                    'mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" "$MYSQL_DB" -e "$INIT_SQL"',
                ],
                "environment": [
                    {"name": "MYSQL_HOST", "value": mysql_host},
                    {"name": "MYSQL_USER", "value": admin_user},
                    {"name": "MYSQL_PWD", "value": admin_password},
                    {"name": "MYSQL_DB", "value": "source_db"},
                    {"name": "INIT_SQL", "value": sql},
                ],
            }
        ]
    }

    network_config = {
        "awsvpcConfiguration": {
            "subnets": subnets,
            "securityGroups": [security_group],
            "assignPublicIp": "DISABLED",
        }
    }

    run = aws_cli(
        region,
        "ecs",
        "run-task",
        "--cluster",
        cluster,
        "--task-definition",
        task_definition,
        "--launch-type",
        "FARGATE",
        "--network-configuration",
        json.dumps(network_config),
        "--overrides",
        json.dumps(overrides),
    )
    if run.returncode != 0:
        sys.exit(f"ecs run-task failed: {run.stderr}")

    task_arn = json.loads(run.stdout)["tasks"][0]["taskArn"]
    print(f"mysql-init task started: {task_arn}")

    task = None
    for _ in range(30):
        describe = aws_cli(region, "ecs", "describe-tasks", "--cluster", cluster, "--tasks", task_arn)
        if describe.returncode != 0:
            sys.exit(f"ecs describe-tasks failed: {describe.stderr}")
        task = json.loads(describe.stdout)["tasks"][0]
        if task["lastStatus"] == "STOPPED":
            break
        time.sleep(5)
    else:
        sys.exit("mysql-init task did not stop in time")

    exit_code = task["containers"][0].get("exitCode")
    if exit_code != 0:
        stream = f"mysql-init/mysql-client/{task_arn.rsplit('/', 1)[-1]}"
        logs = aws_cli(region, "logs", "get-log-events", "--log-group-name", log_group, "--log-stream-name", stream)
        print(logs.stdout, file=sys.stderr)
        sys.exit(f"mysql-init task failed with exit code {exit_code}")

    print("mysql-init completed successfully")


if __name__ == "__main__":
    main()
