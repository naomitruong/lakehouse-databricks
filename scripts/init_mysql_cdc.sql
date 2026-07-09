-- Initialize RDS MySQL (source_db) with the same seed schema/data as the
-- original project's scripts/init_db.sql. Binlog ROW format is enabled via
-- the aws_db_parameter_group.mysql_cdc parameter group in Terraform instead
-- of the --binlog-format/--log-bin docker-compose command flags.

CREATE TABLE IF NOT EXISTS orders (
  order_id INT PRIMARY KEY AUTO_INCREMENT,
  customer_id INT NOT NULL,
  amount DECIMAL(10, 2) NOT NULL,
  order_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- WHERE NOT EXISTS guard (rather than a plain INSERT) makes this safe to
-- re-run — orders has no natural unique key to dedupe against otherwise,
-- since this script is invoked on every `terraform apply` via null_resource
-- mysql_init in terraform/debezium.tf.
INSERT INTO orders (customer_id, amount)
SELECT * FROM (
  VALUES ROW(1, 100.50), ROW(2, 250.00), ROW(3, 75.25), ROW(4, 500.75), ROW(5, 13.00)
) AS seed(customer_id, amount)
WHERE NOT EXISTS (SELECT 1 FROM orders);

CREATE TABLE IF NOT EXISTS customers (
  customer_id INT PRIMARY KEY,
  customer_name VARCHAR(100),
  join_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

INSERT INTO customers (customer_id, customer_name)
SELECT * FROM (
  VALUES ROW(1, 'Alice'), ROW(2, 'Bob'), ROW(3, 'Charlie'), ROW(4, 'Diana'), ROW(5, 'Eric')
) AS seed(customer_id, customer_name)
WHERE NOT EXISTS (SELECT 1 FROM customers);

-- RDS retains only 0 hours of binlog by default — this must be raised or
-- Debezium loses history between snapshot and first streamed event.
CALL mysql.rds_set_configuration('binlog retention hours', 24);

-- Debezium CDC user. RDS's master user is allowed to grant REPLICATION
-- SLAVE/REPLICATION CLIENT directly (unlike SUPER, which RDS blocks), so
-- the grants are otherwise identical to the self-hosted mysqld version.
CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED BY '${DEBEZIUM_MYSQL_PASSWORD}';
-- LOCK TABLES is required for the initial consistent snapshot (Debezium
-- locks tables briefly while it reads the binlog position + existing rows).
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT, LOCK TABLES ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
