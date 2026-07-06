"""
BI Dashboard Integration — export Gold-layer Delta tables to BI platforms.

Replaces bi_dashboards/bi_dashboard.py. The original queried a Snowflake
star schema (or a PostgreSQL fallback) built by a separate warehouse DAG;
here there is a single source of truth — the `lakehouse.gold` Delta tables
that dbt builds — queried through a Databricks SQL Warehouse (the Trino/
Snowflake replacement) via the `databricks-sql-connector`. Same downstream
targets (Tableau, Looker, Power BI) and the same "export to CSV, then push"
shape as the original.
"""

import logging
import os

import pandas as pd
from databricks import sql as databricks_sql

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Databricks SQL Warehouse connection (replaces Snowflake/PostgreSQL creds)
DATABRICKS_HOST = os.getenv("DATABRICKS_HOST", "").replace("https://", "")
DATABRICKS_HTTP_PATH = os.getenv("DATABRICKS_SQL_WAREHOUSE_HTTP_PATH", "")
DATABRICKS_TOKEN = os.getenv("DATABRICKS_TOKEN", "")
UC_CATALOG = os.getenv("UC_CATALOG", "lakehouse")

# BI tool configs — identical to the original
TABLEAU_SERVER = os.getenv("TABLEAU_SERVER", "")
LOOKER_API_URL = os.getenv("LOOKER_API_URL", "")
POWER_BI_WORKSPACE_ID = os.getenv("POWER_BI_WORKSPACE_ID", "")

OUTPUT_DIR = os.getenv("BI_OUTPUT_DIR", "/tmp/bi_exports")

# Gold-layer queries — sourced from lakehouse.gold.fact_orders /
# agg_daily_revenue (the tables dbt/models/gold/*.sql actually builds).
GOLD_QUERIES = {
    "daily_revenue_summary": f"""
        SELECT
            order_date_day,
            total_orders,
            total_revenue,
            avg_order_value
        FROM {UC_CATALOG}.gold.agg_daily_revenue
        ORDER BY order_date_day
    """,
    "customer_order_detail": f"""
        SELECT
            customer_id,
            customer_name,
            COUNT(order_id)     AS total_orders,
            SUM(amount)         AS total_spent,
            AVG(amount)         AS avg_order_value,
            MAX(order_date)     AS last_order_date
        FROM {UC_CATALOG}.gold.fact_orders
        GROUP BY customer_id, customer_name
        ORDER BY total_spent DESC
    """,
}


def get_databricks_connection():
    """Open a connection to the Databricks SQL Warehouse."""
    return databricks_sql.connect(
        server_hostname=DATABRICKS_HOST,
        http_path=DATABRICKS_HTTP_PATH,
        access_token=DATABRICKS_TOKEN,
    )


def export_warehouse_data():
    """Export Gold-layer queries to CSV."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    with get_databricks_connection() as conn:
        for name, query in GOLD_QUERIES.items():
            try:
                df = pd.read_sql(query, conn)
                filepath = os.path.join(OUTPUT_DIR, f"{name}.csv")
                df.to_csv(filepath, index=False)
                logger.info("Exported %s: %d rows -> %s", name, len(df), filepath)
            except Exception as e:
                logger.error("Failed to export %s: %s", name, e)


def upload_to_tableau():
    """Upload datasets to Tableau via REST API."""
    import requests

    if not TABLEAU_SERVER:
        logger.info("Tableau not configured, skipping.")
        return

    site_id = os.getenv("TABLEAU_SITE_ID", "")
    username = os.getenv("TABLEAU_USERNAME", "admin")
    password = os.getenv("TABLEAU_PASSWORD", "")

    try:
        auth_payload = {
            "credentials": {
                "name": username,
                "password": password,
                "site": {"contentUrl": site_id},
            }
        }
        resp = requests.post(
            f"{TABLEAU_SERVER}/api/3.9/auth/signin",
            json=auth_payload,
            timeout=30,
        )
        resp.raise_for_status()
        token = resp.json()["credentials"]["token"]

        for csv_file in os.listdir(OUTPUT_DIR):
            if not csv_file.endswith(".csv"):
                continue
            filepath = os.path.join(OUTPUT_DIR, csv_file)
            with open(filepath, "rb") as f:
                upload_resp = requests.post(
                    f"{TABLEAU_SERVER}/api/3.9/sites/{site_id}/datasources",
                    headers={"X-Tableau-Auth": token},
                    files={"file": f},
                    timeout=60,
                )
                if upload_resp.ok:
                    logger.info("Uploaded %s to Tableau.", csv_file)
                else:
                    logger.error("Tableau upload failed for %s: %s", csv_file, upload_resp.text)

    except Exception as e:
        logger.error("Tableau upload error: %s", e)


def upload_to_looker():
    """Authenticate against Looker. Best practice: connect Looker directly
    to the Databricks SQL Warehouse (native connector) rather than pushing
    CSVs — this function mirrors the original's shape for parity."""
    import requests

    if not LOOKER_API_URL:
        logger.info("Looker not configured, skipping.")
        return

    try:
        auth_resp = requests.post(
            f"{LOOKER_API_URL}/login",
            data={
                "client_id": os.getenv("LOOKER_CLIENT_ID", ""),
                "client_secret": os.getenv("LOOKER_CLIENT_SECRET", ""),
            },
            timeout=30,
        )
        auth_resp.raise_for_status()
        logger.info("Authenticated with Looker. Connect Looker to the Databricks SQL Warehouse directly for best results.")
    except Exception as e:
        logger.error("Looker auth error: %s", e)


def upload_to_power_bi():
    """Push datasets to Power BI via REST API."""
    import requests

    if not POWER_BI_WORKSPACE_ID:
        logger.info("Power BI not configured, skipping.")
        return

    access_token = os.getenv("POWER_BI_ACCESS_TOKEN", "")
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }

    try:
        dataset_payload = {
            "name": "Lakehouse Gold Data",
            "defaultMode": "Push",
            "tables": [
                {
                    "name": "daily_revenue",
                    "columns": [
                        {"name": "order_date_day", "dataType": "DateTime"},
                        {"name": "total_orders", "dataType": "Int64"},
                        {"name": "total_revenue", "dataType": "Double"},
                        {"name": "avg_order_value", "dataType": "Double"},
                    ],
                }
            ],
        }
        resp = requests.post(
            f"https://api.powerbi.com/v1.0/myorg/groups/{POWER_BI_WORKSPACE_ID}/datasets",
            headers=headers,
            json=dataset_payload,
            timeout=30,
        )
        if resp.ok:
            logger.info("Power BI dataset created/updated.")
        else:
            logger.warning("Power BI response: %s", resp.text)
    except Exception as e:
        logger.error("Power BI error: %s", e)


if __name__ == "__main__":
    export_warehouse_data()
    upload_to_tableau()
    upload_to_looker()
    upload_to_power_bi()
