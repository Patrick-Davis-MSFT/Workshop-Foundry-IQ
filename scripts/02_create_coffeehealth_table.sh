#!/usr/bin/env bash
set -euo pipefail

# Creates a CoffeeHealth table in Azure Database for MySQL Flexible Server
# and loads data from the CoffeeHealth CSV stored in blob container "coffeehealth".
#
# Usage:
#   ./scripts/02_create_coffeehealth_table.sh [mysql-endpoint] [mysql-username] [mysql-password]
#
# Optional env vars:
#   MYSQL_ENDPOINT, MYSQL_ADMIN_USERNAME, MYSQL_ADMIN_PASSWORD, STORAGE_ACCOUNT_NAME

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

MYSQL_ENDPOINT="${1:-${MYSQL_ENDPOINT:-}}"
MYSQL_ADMIN_USERNAME="${2:-${MYSQL_ADMIN_USERNAME:-}}"
MYSQL_ADMIN_PASSWORD="${3:-${MYSQL_ADMIN_PASSWORD:-}}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"

if [[ -z "$MYSQL_ENDPOINT" ]]; then
  prompt_value "Enter MySQL endpoint (example: mysqlpcddemo.mysql.database.azure.com)" MYSQL_ENDPOINT
fi

if [[ -z "$MYSQL_ADMIN_USERNAME" ]]; then
  prompt_value "Enter MySQL username" MYSQL_ADMIN_USERNAME
fi

if [[ -z "$MYSQL_ADMIN_PASSWORD" ]]; then
  prompt_value "Enter MySQL password" MYSQL_ADMIN_PASSWORD true
fi

# Normalize endpoint if server name is provided without full domain.
if [[ "$MYSQL_ENDPOINT" != *"."* ]]; then
  MYSQL_ENDPOINT="${MYSQL_ENDPOINT}.mysql.database.azure.com"
fi

MYSQL_SERVER_NAME="${MYSQL_ENDPOINT%%.*}"
USER_INPUT="${MYSQL_SERVER_NAME#mysql}"
RG_NAME="rg_${USER_INPUT}"

if ! command -v az >/dev/null 2>&1; then
  echo "Error: Azure CLI (az) is required."
  exit 1
fi

if ! command -v mysql >/dev/null 2>&1; then
  echo "Error: mysql client is required to load CSV data."
  echo "Install it and rerun, for example: sudo apt-get update && sudo apt-get install -y mysql-client"
  exit 1
fi

# If storage account name is not provided, try to infer it from the expected resource group.
if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  STORAGE_ACCOUNT_NAME="$(az storage account list -g "$RG_NAME" --query "[0].name" -o tsv 2>/dev/null || true)"
fi

if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  prompt_value "Enter storage account name that contains container 'coffeehealth'" STORAGE_ACCOUNT_NAME
fi

TMP_CSV="$(mktemp /tmp/coffeehealth.XXXXXX.csv)"
cleanup() {
  rm -f "$TMP_CSV"
}
trap cleanup EXIT

echo "Downloading CoffeeHealth CSV from blob storage..."
az storage blob download \
  --auth-mode login \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name "coffeehealth" \
  --name "synthetic_coffee_health_10000.csv" \
  --file "$TMP_CSV" \
  --overwrite >/dev/null

DB_NAME="coffee"
TABLE_NAME="coffee_health"

MYSQL_SSL_OPTION=""
if mysql --help 2>/dev/null | grep -q -- '--ssl-mode'; then
  MYSQL_SSL_OPTION="--ssl-mode=REQUIRED"
elif mysql --help 2>/dev/null | grep -q -- '--ssl'; then
  MYSQL_SSL_OPTION="--ssl"
fi

echo "Creating MySQL database/table and loading CSV..."
mysql --local-infile=1 \
  --host="$MYSQL_ENDPOINT" \
  --user="$MYSQL_ADMIN_USERNAME" \
  --password="$MYSQL_ADMIN_PASSWORD" \
  ${MYSQL_SSL_OPTION:+$MYSQL_SSL_OPTION} <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
USE ${DB_NAME};

CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (
  ID INT PRIMARY KEY,
  Age INT,
  Gender VARCHAR(20),
  Country VARCHAR(64),
  Coffee_Intake DECIMAL(4,1),
  Caffeine_mg DECIMAL(6,1),
  Sleep_Hours DECIMAL(3,1),
  Sleep_Quality VARCHAR(20),
  BMI DECIMAL(4,1),
  Heart_Rate INT,
  Stress_Level VARCHAR(20),
  Physical_Activity_Hours DECIMAL(4,1),
  Health_Issues VARCHAR(20),
  Occupation VARCHAR(40),
  Smoking TINYINT,
  Alcohol_Consumption TINYINT
);

LOAD DATA LOCAL INFILE '${TMP_CSV}'
REPLACE INTO TABLE ${TABLE_NAME}
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(ID, Age, Gender, Country, Coffee_Intake, Caffeine_mg, Sleep_Hours, Sleep_Quality, BMI, Heart_Rate, Stress_Level, Physical_Activity_Hours, Health_Issues, Occupation, Smoking, Alcohol_Consumption);

SELECT COUNT(*) AS row_count FROM ${TABLE_NAME};
SQL

echo "Completed."
echo "MySQL endpoint: $MYSQL_ENDPOINT"
echo "Database/Table: ${DB_NAME}.${TABLE_NAME}"
echo "Storage account: $STORAGE_ACCOUNT_NAME"
