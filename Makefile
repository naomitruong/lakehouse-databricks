.PHONY: tf-init tf-plan tf-apply tf-destroy register-debezium bundle-deploy bundle-run dbt-run dbt-test dbt-docs bi-export

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
bundle-deploy:
	databricks bundle deploy -t dev

bundle-run:
	databricks bundle run lakehouse_orchestration_job -t dev

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
