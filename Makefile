.PHONY: tf-init tf-plan tf-apply tf-destroy register-debezium bundle-deploy bundle-run bundle-run-bronze dbt-run dbt-test dbt-docs bi-export

# ---- Terraform (AWS + Databricks infra) ----
tf-init:
	cd terraform && terraform init

tf-plan:
	cd terraform && terraform plan -var-file=terraform.tfvars

tf-apply:
	cd terraform && terraform apply -var-file=terraform.tfvars

tf-destroy:
	cd terraform && terraform destroy -var-file=terraform.tfvars

# ---- CDC ----
register-debezium:
	bash scripts/register_debezium.sh

# ---- Databricks Workflows (Asset Bundle) — replaces `airflow dags trigger` ----
# Pin the profile rather than relying on default_profile in ~/.databrickscfg,
# which is how an earlier deploy went to the wrong workspace.
DATABRICKS_PROFILE ?= newacct

bundle-deploy:
	databricks bundle deploy -t dev --profile $(DATABRICKS_PROFILE)

bundle-run:
	databricks bundle run dbt_orchestration_job -t dev --profile $(DATABRICKS_PROFILE)

bundle-run-bronze:
	databricks bundle run cdc_bronze_ingestion_job -t dev --profile $(DATABRICKS_PROFILE)

# ---- dbt (dbt-databricks adapter, run against the SQL Warehouse) ----
dbt-run:
	cd dbt && dbt run

dbt-test:
	cd dbt && dbt test

dbt-docs:
	cd dbt && dbt docs generate && dbt docs serve --port 8087

# ---- BI export ----
bi-export:
	python3 bi/bi_dashboard.py
