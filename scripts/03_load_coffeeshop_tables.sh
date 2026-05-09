#!/usr/bin/env bash
set -euo pipefail

# Creates CoffeeShop relational tables in Azure SQL Database and loads CSV data.
# Rerunnable without duplicate data via upsert + dedupe load logic.
#
# Usage:
#   ./scripts/03_load_coffeeshop_tables.sh [sql-server-fqdn] [sql-admin-username] [sql-admin-password] [database-name]
#
# Optional env vars:
#   SQL_SERVER_FQDN, SQL_ADMIN_USERNAME, SQL_ADMIN_PASSWORD, SQL_DATABASE, COFFEESHOP_DATA_ROOT

prompt_value() {
  local prompt_text="$1"
  local var_name="$2"
  local is_secret="${3:-false}"

  if [[ "$is_secret" == "true" ]]; then
    read -r -s -p "$prompt_text: " "$var_name"
    echo
  else
    read -r -p "$prompt_text: " "$var_name"
  fi
}

log_step() {
  echo "[03-loader] $1"
}

ensure_sql_tools() {
  if command -v sqlcmd >/dev/null 2>&1 && command -v bcp >/dev/null 2>&1; then
    return
  fi

  # Common install locations for mssql-tools.
  if [[ -d "/opt/mssql-tools18/bin" ]]; then
    export PATH="/opt/mssql-tools18/bin:$PATH"
  elif [[ -d "/opt/mssql-tools/bin" ]]; then
    export PATH="/opt/mssql-tools/bin:$PATH"
  fi

  if ! command -v sqlcmd >/dev/null 2>&1; then
    echo "Error: sqlcmd is required."
    echo "Install mssql-tools18 (or rebuild the dev container) and ensure sqlcmd is on PATH."
    exit 1
  fi

  if ! command -v bcp >/dev/null 2>&1; then
    echo "Error: bcp is required."
    echo "Install mssql-tools18 (or rebuild the dev container) and ensure bcp is on PATH."
    exit 1
  fi
}

SCRIPT_START_EPOCH="$(date +%s)"

SQL_SERVER_FQDN="${1:-${SQL_SERVER_FQDN:-${MYSQL_ENDPOINT:-}}}"
SQL_ADMIN_USERNAME="${2:-${SQL_ADMIN_USERNAME:-${MYSQL_ADMIN_USERNAME:-}}}"
SQL_ADMIN_PASSWORD="${3:-${SQL_ADMIN_PASSWORD:-${MYSQL_ADMIN_PASSWORD:-}}}"
SQL_DATABASE="${4:-${SQL_DATABASE:-coffee_shop}}"
COFFEESHOP_DATA_ROOT="${COFFEESHOP_DATA_ROOT:-}"

if [[ -z "$SQL_SERVER_FQDN" ]]; then
  prompt_value "Enter SQL server endpoint (example: sqlpcddemo.database.windows.net)" SQL_SERVER_FQDN
fi
if [[ -z "$SQL_ADMIN_USERNAME" ]]; then
  prompt_value "Enter SQL admin username" SQL_ADMIN_USERNAME
fi
if [[ -z "$SQL_ADMIN_PASSWORD" ]]; then
  prompt_value "Enter SQL admin password" SQL_ADMIN_PASSWORD true
fi
if [[ -z "$SQL_DATABASE" ]]; then
  prompt_value "Enter SQL database name" SQL_DATABASE
fi

# Normalize endpoint if user provides only server name.
if [[ "$SQL_SERVER_FQDN" != *"."* ]]; then
  SQL_SERVER_FQDN="${SQL_SERVER_FQDN}.database.windows.net"
fi

ensure_sql_tools

if [[ -z "$COFFEESHOP_DATA_ROOT" ]]; then
  if [[ -d "data/Coffee/CoffeeShop" ]]; then
    COFFEESHOP_DATA_ROOT="data/Coffee/CoffeeShop"
  elif [[ -d "data/CoffeeShop" ]]; then
    COFFEESHOP_DATA_ROOT="data/CoffeeShop"
  fi
fi

if [[ -z "$COFFEESHOP_DATA_ROOT" || ! -d "$COFFEESHOP_DATA_ROOT" ]]; then
  echo "Error: CoffeeShop data folder not found."
  echo "Set COFFEESHOP_DATA_ROOT to the folder that contains menu_items/, payment_methods/, stores/, users/, vouchers/, transactions/, transaction_items/."
  exit 1
fi

MENU_ITEMS_FILE="$COFFEESHOP_DATA_ROOT/menu_items/menu_items.csv"
PAYMENT_METHODS_FILE="$COFFEESHOP_DATA_ROOT/payment_methods/payment_methods.csv"
STORES_FILE="$COFFEESHOP_DATA_ROOT/stores/stores.csv"
VOUCHERS_FILE="$COFFEESHOP_DATA_ROOT/vouchers/vouchers.csv"
USERS_GLOB="$COFFEESHOP_DATA_ROOT/users/users_*.csv"
TRANSACTIONS_GLOB="$COFFEESHOP_DATA_ROOT/transactions/transactions_*.csv"
TRANSACTION_ITEMS_GLOB="$COFFEESHOP_DATA_ROOT/transaction_items/transaction_items_*.csv"

for req in "$MENU_ITEMS_FILE" "$PAYMENT_METHODS_FILE" "$STORES_FILE" "$VOUCHERS_FILE"; do
  if [[ ! -f "$req" ]]; then
    echo "Error: required file not found: $req"
    exit 1
  fi
done

TMP_DIR="$(mktemp -d /tmp/coffeeshop-load.XXXXXX)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

USERS_MERGED="$TMP_DIR/users_all.csv"
TRANSACTIONS_MERGED="$TMP_DIR/transactions_all.csv"
TRANSACTION_ITEMS_MERGED="$TMP_DIR/transaction_items_all.csv"

concat_csv_parts() {
  local pattern="$1"
  local output_file="$2"

  shopt -s nullglob
  local files=( $pattern )
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    echo "Error: no CSV files found for pattern: $pattern"
    exit 1
  fi

  : > "$output_file"
  local first=1
  local f
  for f in "${files[@]}"; do
    if (( first == 1 )); then
      cat "$f" >> "$output_file"
      first=0
    else
      tail -n +2 "$f" >> "$output_file"
    fi
  done
}

concat_csv_parts "$USERS_GLOB" "$USERS_MERGED"
log_step "Merged users CSV files -> $USERS_MERGED ($(wc -l < "$USERS_MERGED") lines)"
concat_csv_parts "$TRANSACTIONS_GLOB" "$TRANSACTIONS_MERGED"
log_step "Merged transactions CSV files -> $TRANSACTIONS_MERGED ($(wc -l < "$TRANSACTIONS_MERGED") lines)"
concat_csv_parts "$TRANSACTION_ITEMS_GLOB" "$TRANSACTION_ITEMS_MERGED"
log_step "Merged transaction_items CSV files -> $TRANSACTION_ITEMS_MERGED ($(wc -l < "$TRANSACTION_ITEMS_MERGED") lines)"

run_sql() {
  local db_name="$1"
  local sql_text="$2"
  sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d "$db_name" -N -C -b -Q "$sql_text"
}

bcp_load() {
  local table_name="$1"
  local csv_file="$2"
  local error_file="$3"
  bcp "${SQL_DATABASE}.dbo.${table_name}" in "$csv_file" \
    -S "tcp:${SQL_SERVER_FQDN},1433" \
    -U "$SQL_ADMIN_USERNAME" \
    -P "$SQL_ADMIN_PASSWORD" \
    -c -t "," -F 2 -q -b 10000 -e "$error_file"
}

log_step "Connecting to Azure SQL endpoint: $SQL_SERVER_FQDN"
run_sql master "IF DB_ID(N'${SQL_DATABASE}') IS NULL CREATE DATABASE [${SQL_DATABASE}];"

log_step "Creating target and staging tables in database: $SQL_DATABASE"
sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d "$SQL_DATABASE" -N -C -b <<SQL
IF OBJECT_ID('dbo.menu_items', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.menu_items (
    item_id INT NOT NULL PRIMARY KEY,
    item_name VARCHAR(128) NOT NULL,
    category VARCHAR(50) NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    is_seasonal BIT NOT NULL,
    available_from DATE NULL,
    available_to DATE NULL
  );
END

IF OBJECT_ID('dbo.payment_methods', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.payment_methods (
    payment_method_id INT NOT NULL PRIMARY KEY,
    method_name VARCHAR(50) NOT NULL,
    category VARCHAR(50) NOT NULL
  );
END

IF OBJECT_ID('dbo.stores', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stores (
    store_id INT NOT NULL PRIMARY KEY,
    store_name VARCHAR(255) NOT NULL,
    street VARCHAR(255) NOT NULL,
    postal_code VARCHAR(20) NOT NULL,
    city VARCHAR(100) NOT NULL,
    state VARCHAR(100) NOT NULL,
    latitude DECIMAL(10,6) NOT NULL,
    longitude DECIMAL(10,6) NOT NULL
  );
END

IF OBJECT_ID('dbo.users', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.users (
    user_id BIGINT NOT NULL PRIMARY KEY,
    gender VARCHAR(20) NOT NULL,
    birthdate DATE NOT NULL,
    registered_at DATETIME2 NOT NULL
  );
END

IF OBJECT_ID('dbo.vouchers', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.vouchers (
    voucher_id INT NOT NULL PRIMARY KEY,
    voucher_code VARCHAR(50) NOT NULL,
    discount_type VARCHAR(20) NOT NULL,
    discount_value DECIMAL(10,2) NOT NULL,
    valid_from DATE NOT NULL,
    valid_to DATE NOT NULL
  );
END

IF OBJECT_ID('dbo.transactions', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.transactions (
    transaction_id CHAR(36) NOT NULL PRIMARY KEY,
    store_id INT NOT NULL,
    payment_method_id INT NOT NULL,
    voucher_id INT NULL,
    user_id BIGINT NULL,
    original_amount DECIMAL(10,2) NOT NULL,
    discount_applied DECIMAL(10,2) NOT NULL,
    final_amount DECIMAL(10,2) NOT NULL,
    created_at DATETIME2 NOT NULL
  );
END

IF OBJECT_ID('dbo.transaction_items', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.transaction_items (
    transaction_id CHAR(36) NOT NULL,
    item_id INT NOT NULL,
    quantity INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    subtotal DECIMAL(10,2) NOT NULL,
    created_at DATETIME2 NOT NULL
  );
END

-- Ensure transaction_items has no primary key and keeps a non-unique lookup index on transaction_id.
DECLARE @transaction_items_pk_name SYSNAME;
SELECT @transaction_items_pk_name = kc.name
FROM sys.key_constraints kc
WHERE kc.parent_object_id = OBJECT_ID('dbo.transaction_items')
  AND kc.[type] = 'PK';

IF @transaction_items_pk_name IS NOT NULL
BEGIN
  EXEC('ALTER TABLE dbo.transaction_items DROP CONSTRAINT [' + @transaction_items_pk_name + ']');
END

IF NOT EXISTS (
  SELECT 1
  FROM sys.indexes
  WHERE object_id = OBJECT_ID('dbo.transaction_items')
    AND name = 'ix_transaction_items_transaction_id'
)
BEGIN
  CREATE NONCLUSTERED INDEX ix_transaction_items_transaction_id
    ON dbo.transaction_items(transaction_id);
END

IF OBJECT_ID('dbo.stg_menu_items', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_menu_items (
    item_id VARCHAR(64) NULL,
    item_name VARCHAR(255) NULL,
    category VARCHAR(64) NULL,
    price VARCHAR(64) NULL,
    is_seasonal VARCHAR(16) NULL,
    available_from VARCHAR(32) NULL,
    available_to VARCHAR(32) NULL
  );
END

IF OBJECT_ID('dbo.stg_payment_methods', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_payment_methods (
    method_id VARCHAR(64) NULL,
    method_name VARCHAR(64) NULL,
    category VARCHAR(64) NULL
  );
END

IF OBJECT_ID('dbo.stg_stores', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_stores (
    store_id VARCHAR(64) NULL,
    store_name VARCHAR(255) NULL,
    street VARCHAR(255) NULL,
    postal_code VARCHAR(64) NULL,
    city VARCHAR(128) NULL,
    state VARCHAR(128) NULL,
    latitude VARCHAR(64) NULL,
    longitude VARCHAR(64) NULL
  );
END

IF OBJECT_ID('dbo.stg_users', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_users (
    user_id VARCHAR(64) NULL,
    gender VARCHAR(20) NULL,
    birthdate VARCHAR(32) NULL,
    registered_at VARCHAR(32) NULL
  );
END

IF OBJECT_ID('dbo.stg_vouchers', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_vouchers (
    voucher_id VARCHAR(64) NULL,
    voucher_code VARCHAR(64) NULL,
    discount_type VARCHAR(32) NULL,
    discount_value VARCHAR(64) NULL,
    valid_from VARCHAR(32) NULL,
    valid_to VARCHAR(32) NULL
  );
END

IF OBJECT_ID('dbo.stg_transactions', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_transactions (
    transaction_id VARCHAR(64) NULL,
    store_id VARCHAR(64) NULL,
    payment_method_id VARCHAR(64) NULL,
    voucher_id VARCHAR(64) NULL,
    user_id VARCHAR(64) NULL,
    original_amount VARCHAR(64) NULL,
    discount_applied VARCHAR(64) NULL,
    final_amount VARCHAR(64) NULL,
    created_at VARCHAR(32) NULL
  );
END

IF OBJECT_ID('dbo.stg_transaction_items', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.stg_transaction_items (
    transaction_id VARCHAR(64) NULL,
    item_id VARCHAR(64) NULL,
    quantity VARCHAR(64) NULL,
    unit_price VARCHAR(64) NULL,
    subtotal VARCHAR(64) NULL,
    created_at VARCHAR(32) NULL
  );
END

TRUNCATE TABLE dbo.stg_menu_items;
TRUNCATE TABLE dbo.stg_payment_methods;
TRUNCATE TABLE dbo.stg_stores;
TRUNCATE TABLE dbo.stg_users;
TRUNCATE TABLE dbo.stg_vouchers;
TRUNCATE TABLE dbo.stg_transactions;
TRUNCATE TABLE dbo.stg_transaction_items;
SQL

log_step "Bulk loading source CSV files into staging tables"
bcp_load stg_menu_items "$MENU_ITEMS_FILE" /tmp/stg_menu_items.err
bcp_load stg_payment_methods "$PAYMENT_METHODS_FILE" /tmp/stg_payment_methods.err
bcp_load stg_stores "$STORES_FILE" /tmp/stg_stores.err
bcp_load stg_users "$USERS_MERGED" /tmp/stg_users.err
bcp_load stg_vouchers "$VOUCHERS_FILE" /tmp/stg_vouchers.err
bcp_load stg_transactions "$TRANSACTIONS_MERGED" /tmp/stg_transactions.err
bcp_load stg_transaction_items "$TRANSACTION_ITEMS_MERGED" /tmp/stg_transaction_items.err

log_step "Upserting dimensions and facts (Takes a while)..."
sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d "$SQL_DATABASE" -N -C -b <<SQL
SET XACT_ABORT ON;

MERGE dbo.menu_items AS t
USING (
  SELECT
    TRY_CONVERT(INT, item_id) AS item_id,
    item_name,
    category,
    TRY_CONVERT(DECIMAL(10,2), price) AS price,
    CASE WHEN LOWER(LTRIM(RTRIM(is_seasonal))) IN ('true','1','yes') THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_seasonal,
    TRY_CONVERT(DATE, NULLIF(available_from, '')) AS available_from,
    TRY_CONVERT(DATE, NULLIF(available_to, '')) AS available_to
  FROM dbo.stg_menu_items
) AS s
ON t.item_id = s.item_id
WHEN MATCHED THEN UPDATE SET
  item_name = s.item_name,
  category = s.category,
  price = s.price,
  is_seasonal = s.is_seasonal,
  available_from = s.available_from,
  available_to = s.available_to
WHEN NOT MATCHED THEN INSERT (item_id, item_name, category, price, is_seasonal, available_from, available_to)
VALUES (s.item_id, s.item_name, s.category, s.price, s.is_seasonal, s.available_from, s.available_to);

MERGE dbo.payment_methods AS t
USING (
  SELECT TRY_CONVERT(INT, method_id) AS payment_method_id, method_name, category
  FROM dbo.stg_payment_methods
) AS s
ON t.payment_method_id = s.payment_method_id
WHEN MATCHED THEN UPDATE SET method_name = s.method_name, category = s.category
WHEN NOT MATCHED THEN INSERT (payment_method_id, method_name, category) VALUES (s.payment_method_id, s.method_name, s.category);

MERGE dbo.stores AS t
USING (
  SELECT
    TRY_CONVERT(INT, store_id) AS store_id,
    store_name,
    street,
    postal_code,
    city,
    state,
    TRY_CONVERT(DECIMAL(10,6), latitude) AS latitude,
    TRY_CONVERT(DECIMAL(10,6), longitude) AS longitude
  FROM dbo.stg_stores
) AS s
ON t.store_id = s.store_id
WHEN MATCHED THEN UPDATE SET
  store_name = s.store_name,
  street = s.street,
  postal_code = s.postal_code,
  city = s.city,
  state = s.state,
  latitude = s.latitude,
  longitude = s.longitude
WHEN NOT MATCHED THEN INSERT (store_id, store_name, street, postal_code, city, state, latitude, longitude)
VALUES (s.store_id, s.store_name, s.street, s.postal_code, s.city, s.state, s.latitude, s.longitude);

MERGE dbo.users AS t
USING (
  SELECT
    TRY_CONVERT(BIGINT, REPLACE(user_id, '.0', '')) AS user_id,
    gender,
    TRY_CONVERT(DATE, birthdate) AS birthdate,
    TRY_CONVERT(DATETIME2, registered_at) AS registered_at
  FROM dbo.stg_users
) AS s
ON t.user_id = s.user_id
WHEN MATCHED THEN UPDATE SET gender = s.gender, birthdate = s.birthdate, registered_at = s.registered_at
WHEN NOT MATCHED THEN INSERT (user_id, gender, birthdate, registered_at)
VALUES (s.user_id, s.gender, s.birthdate, s.registered_at);

MERGE dbo.vouchers AS t
USING (
  SELECT
    TRY_CONVERT(INT, voucher_id) AS voucher_id,
    voucher_code,
    discount_type,
    TRY_CONVERT(DECIMAL(10,2), discount_value) AS discount_value,
    TRY_CONVERT(DATE, valid_from) AS valid_from,
    TRY_CONVERT(DATE, valid_to) AS valid_to
  FROM dbo.stg_vouchers
) AS s
ON t.voucher_id = s.voucher_id
WHEN MATCHED THEN UPDATE SET
  voucher_code = s.voucher_code,
  discount_type = s.discount_type,
  discount_value = s.discount_value,
  valid_from = s.valid_from,
  valid_to = s.valid_to
WHEN NOT MATCHED THEN INSERT (voucher_id, voucher_code, discount_type, discount_value, valid_from, valid_to)
VALUES (s.voucher_id, s.voucher_code, s.discount_type, s.discount_value, s.valid_from, s.valid_to);

MERGE dbo.transactions AS t
USING (
  SELECT
    transaction_id,
    TRY_CONVERT(INT, store_id) AS store_id,
    TRY_CONVERT(INT, payment_method_id) AS payment_method_id,
    TRY_CONVERT(INT, NULLIF(REPLACE(voucher_id, '.0', ''), '')) AS voucher_id,
    TRY_CONVERT(BIGINT, NULLIF(REPLACE(user_id, '.0', ''), '')) AS user_id,
    TRY_CONVERT(DECIMAL(10,2), original_amount) AS original_amount,
    TRY_CONVERT(DECIMAL(10,2), discount_applied) AS discount_applied,
    TRY_CONVERT(DECIMAL(10,2), final_amount) AS final_amount,
    TRY_CONVERT(DATETIME2, created_at) AS created_at
  FROM dbo.stg_transactions
) AS s
ON t.transaction_id = s.transaction_id
WHEN MATCHED THEN UPDATE SET
  store_id = s.store_id,
  payment_method_id = s.payment_method_id,
  voucher_id = s.voucher_id,
  user_id = s.user_id,
  original_amount = s.original_amount,
  discount_applied = s.discount_applied,
  final_amount = s.final_amount,
  created_at = s.created_at
WHEN NOT MATCHED THEN INSERT (transaction_id, store_id, payment_method_id, voucher_id, user_id, original_amount, discount_applied, final_amount, created_at)
VALUES (s.transaction_id, s.store_id, s.payment_method_id, s.voucher_id, s.user_id, s.original_amount, s.discount_applied, s.final_amount, s.created_at);

;WITH transaction_items_source AS (
  SELECT
    transaction_id,
    TRY_CONVERT(INT, item_id) AS item_id,
    TRY_CONVERT(INT, quantity) AS quantity,
    TRY_CONVERT(DECIMAL(10,2), unit_price) AS unit_price,
    TRY_CONVERT(DECIMAL(10,2), subtotal) AS subtotal,
    TRY_CONVERT(DATETIME2, created_at) AS created_at
  FROM dbo.stg_transaction_items
),
transaction_items_clean AS (
  SELECT DISTINCT
    transaction_id,
    item_id,
    quantity,
    unit_price,
    subtotal,
    created_at
  FROM transaction_items_source
  WHERE transaction_id IS NOT NULL
    AND item_id IS NOT NULL
    AND quantity IS NOT NULL
    AND unit_price IS NOT NULL
    AND subtotal IS NOT NULL
    AND created_at IS NOT NULL
)
INSERT INTO dbo.transaction_items (transaction_id, item_id, quantity, unit_price, subtotal, created_at)
SELECT
  s.transaction_id,
  s.item_id,
  s.quantity,
  s.unit_price,
  s.subtotal,
  s.created_at
FROM transaction_items_clean s
WHERE EXISTS (
  SELECT 1
  FROM dbo.transactions t
  WHERE t.transaction_id = s.transaction_id
)
AND NOT EXISTS (
  SELECT 1
  FROM dbo.transaction_items t
  WHERE t.transaction_id = s.transaction_id
    AND t.item_id = s.item_id
    AND t.created_at = s.created_at
    AND t.quantity = s.quantity
    AND t.unit_price = s.unit_price
    AND t.subtotal = s.subtotal
);

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transactions_store')
  ALTER TABLE dbo.transactions ADD CONSTRAINT fk_transactions_store FOREIGN KEY (store_id) REFERENCES dbo.stores(store_id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transactions_payment_method')
  ALTER TABLE dbo.transactions ADD CONSTRAINT fk_transactions_payment_method FOREIGN KEY (payment_method_id) REFERENCES dbo.payment_methods(payment_method_id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transactions_voucher')
  ALTER TABLE dbo.transactions ADD CONSTRAINT fk_transactions_voucher FOREIGN KEY (voucher_id) REFERENCES dbo.vouchers(voucher_id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transactions_user')
  ALTER TABLE dbo.transactions ADD CONSTRAINT fk_transactions_user FOREIGN KEY (user_id) REFERENCES dbo.users(user_id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transaction_items_transaction')
  ALTER TABLE dbo.transaction_items ADD CONSTRAINT fk_transaction_items_transaction FOREIGN KEY (transaction_id) REFERENCES dbo.transactions(transaction_id);
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_transaction_items_item')
  ALTER TABLE dbo.transaction_items ADD CONSTRAINT fk_transaction_items_item FOREIGN KEY (item_id) REFERENCES dbo.menu_items(item_id);

SELECT 'menu_items' AS table_name, COUNT(*) AS row_count FROM dbo.menu_items
UNION ALL SELECT 'payment_methods', COUNT(*) FROM dbo.payment_methods
UNION ALL SELECT 'stores', COUNT(*) FROM dbo.stores
UNION ALL SELECT 'users', COUNT(*) FROM dbo.users
UNION ALL SELECT 'vouchers', COUNT(*) FROM dbo.vouchers
UNION ALL SELECT 'transactions', COUNT(*) FROM dbo.transactions
UNION ALL SELECT 'transaction_items', COUNT(*) FROM dbo.transaction_items;
SQL

log_step "CoffeeShop load completed."
log_step "SQL server endpoint: $SQL_SERVER_FQDN"
log_step "Database: $SQL_DATABASE"
log_step "Data root: $COFFEESHOP_DATA_ROOT"

SCRIPT_END_EPOCH="$(date +%s)"
TOTAL_RUNTIME_SECONDS=$((SCRIPT_END_EPOCH - SCRIPT_START_EPOCH))
TOTAL_RUNTIME_HOURS=$((TOTAL_RUNTIME_SECONDS / 3600))
TOTAL_RUNTIME_MINUTES=$(((TOTAL_RUNTIME_SECONDS % 3600) / 60))
TOTAL_RUNTIME_REMAINING_SECONDS=$((TOTAL_RUNTIME_SECONDS % 60))

log_step "Total runtime: ${TOTAL_RUNTIME_HOURS}h ${TOTAL_RUNTIME_MINUTES}m ${TOTAL_RUNTIME_REMAINING_SECONDS}s (${TOTAL_RUNTIME_SECONDS} seconds)"
