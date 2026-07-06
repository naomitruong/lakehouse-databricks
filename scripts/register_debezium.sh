#!/bin/bash
# register_debezium.sh — register the MySQL CDC connector against a
# Kafka Connect REST endpoint (self-managed worker or MSK Connect's
# REST proxy). Same call shape as the original project; only the target
# host changes (env var instead of hardcoded localhost:8083).
set -euo pipefail

CONNECT_URL="${DEBEZIUM_CONNECT_URL:-http://localhost:8083}"

envsubst < debezium/connectors/mysql-source.json > /tmp/mysql-source.rendered.json

curl -s -X POST "${CONNECT_URL}/connectors" \
  -H "Content-Type: application/json" \
  -d @/tmp/mysql-source.rendered.json | python3 -m json.tool
