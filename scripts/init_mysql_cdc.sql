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

INSERT INTO orders (customer_id, amount) VALUES
(1, 100.50),
(2, 250.00),
(3, 75.25),
(4, 500.75),
(5, 13.00);

CREATE TABLE IF NOT EXISTS customers (
  customer_id INT PRIMARY KEY,
  customer_name VARCHAR(100),
  join_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

INSERT INTO customers (customer_id, customer_name) VALUES
(1, 'Alice'),
(2, 'Bob'),
(3, 'Charlie'),
(4, 'Diana'),
(5, 'Eric');

-- RDS retains only 0 hours of binlog by default — this must be raised or
-- Debezium loses history between snapshot and first streamed event.
CALL mysql.rds_set_configuration('binlog retention hours', 24);

-- Debezium CDC user. RDS's master user is allowed to grant REPLICATION
-- SLAVE/REPLICATION CLIENT directly (unlike SUPER, which RDS blocks), so
-- the grants are otherwise identical to the self-hosted mysqld version.
CREATE USER IF NOT EXISTS 'debezium'@'%' IDENTIFIED BY '${DEBEZIUM_MYSQL_PASSWORD}';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
