#!/usr/bin/env bash
set -euo pipefail

# Creates a CoffeeHealth table in Azure SQL Database
# and loads data from the CoffeeHealth CSV stored in blob container "coffeehealth".
#
# Usage:
#   ./scripts/02_create_coffeehealth_table.sh [sql-server-fqdn] [sql-admin-username] [sql-admin-password] [database-name]
#
# Optional env vars:
#   SQL_SERVER_FQDN, SQL_ADMIN_USERNAME, SQL_ADMIN_PASSWORD, SQL_DATABASE, STORAGE_ACCOUNT_NAME

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
    echo "Error: sqlcmd is required to load data into Azure SQL Database."
    echo "Install mssql-tools18 (or rebuild the dev container) and ensure sqlcmd is on PATH."
    exit 1
  fi

  if ! command -v bcp >/dev/null 2>&1; then
    echo "Error: bcp is required to bulk-load CSV data into Azure SQL Database."
    echo "Install mssql-tools18 (or rebuild the dev container) and ensure bcp is on PATH."
    exit 1
  fi
}

SQL_SERVER_FQDN="${1:-${SQL_SERVER_FQDN:-${MYSQL_ENDPOINT:-}}}"
SQL_ADMIN_USERNAME="${2:-${SQL_ADMIN_USERNAME:-${MYSQL_ADMIN_USERNAME:-}}}"
SQL_ADMIN_PASSWORD="${3:-${SQL_ADMIN_PASSWORD:-${MYSQL_ADMIN_PASSWORD:-}}}"
SQL_DATABASE="${4:-${SQL_DATABASE:-coffee_health}}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-}"

if [[ -z "$SQL_SERVER_FQDN" ]]; then
  prompt_value "Enter SQL server endpoint (example: sqlpcddemo.database.windows.net)" SQL_SERVER_FQDN
fi

if [[ -z "$SQL_ADMIN_USERNAME" ]]; then
  prompt_value "Enter SQL admin username" SQL_ADMIN_USERNAME
fi

if [[ -z "$SQL_ADMIN_PASSWORD" ]]; then
  prompt_value "Enter SQL admin password" SQL_ADMIN_PASSWORD true
fi

# Normalize endpoint if server name is provided without full domain.
if [[ "$SQL_SERVER_FQDN" != *"."* ]]; then
  SQL_SERVER_FQDN="${SQL_SERVER_FQDN}.database.windows.net"
fi

SQL_SERVER_NAME="${SQL_SERVER_FQDN%%.*}"
USER_INPUT="${SQL_SERVER_NAME#sql}"
RG_NAME="rg_${USER_INPUT}"

if ! command -v az >/dev/null 2>&1; then
  echo "Error: Azure CLI (az) is required."
  exit 1
fi

ensure_sql_tools

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

DB_NAME="$SQL_DATABASE"
TABLE_NAME="coffee_health"
STAGING_TABLE="coffee_health_staging"

echo "Ensuring Azure SQL database exists..."
sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d master -N -C -b -Q "IF DB_ID(N'${DB_NAME}') IS NULL CREATE DATABASE [${DB_NAME}];"

echo "Creating Azure SQL tables..."
sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d "$DB_NAME" -N -C -b <<SQL
IF OBJECT_ID('dbo.${TABLE_NAME}', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.${TABLE_NAME} (
    ID INT NOT NULL PRIMARY KEY,
    Age INT NULL,
    Gender VARCHAR(20) NULL,
    Country VARCHAR(64) NULL,
    Coffee_Intake DECIMAL(4,1) NULL,
    Caffeine_mg DECIMAL(6,1) NULL,
    Sleep_Hours DECIMAL(3,1) NULL,
    Sleep_Quality VARCHAR(20) NULL,
    BMI DECIMAL(4,1) NULL,
    Heart_Rate INT NULL,
    Stress_Level VARCHAR(20) NULL,
    Physical_Activity_Hours DECIMAL(4,1) NULL,
    Health_Issues VARCHAR(20) NULL,
    Occupation VARCHAR(40) NULL,
    Smoking TINYINT NULL,
    Alcohol_Consumption TINYINT NULL
  );
END

IF OBJECT_ID('dbo.${STAGING_TABLE}', 'U') IS NULL
BEGIN
  CREATE TABLE dbo.${STAGING_TABLE} (
    ID INT NULL,
    Age INT NULL,
    Gender VARCHAR(20) NULL,
    Country VARCHAR(64) NULL,
    Coffee_Intake DECIMAL(4,1) NULL,
    Caffeine_mg DECIMAL(6,1) NULL,
    Sleep_Hours DECIMAL(3,1) NULL,
    Sleep_Quality VARCHAR(20) NULL,
    BMI DECIMAL(4,1) NULL,
    Heart_Rate INT NULL,
    Stress_Level VARCHAR(20) NULL,
    Physical_Activity_Hours DECIMAL(4,1) NULL,
    Health_Issues VARCHAR(20) NULL,
    Occupation VARCHAR(40) NULL,
    Smoking TINYINT NULL,
    Alcohol_Consumption TINYINT NULL
  );
END

TRUNCATE TABLE dbo.${STAGING_TABLE};
SQL

echo "Bulk loading CSV into staging table..."
bcp "${DB_NAME}.dbo.${STAGING_TABLE}" in "$TMP_CSV" \
  -S "tcp:${SQL_SERVER_FQDN},1433" \
  -U "$SQL_ADMIN_USERNAME" \
  -P "$SQL_ADMIN_PASSWORD" \
  -c -t "," -F 2 -q -b 10000 -e /tmp/coffee_health_bcp_errors.txt

echo "Merging staging data into target table..."
sqlcmd -S "tcp:${SQL_SERVER_FQDN},1433" -U "$SQL_ADMIN_USERNAME" -P "$SQL_ADMIN_PASSWORD" -d "$DB_NAME" -N -C -b <<SQL
MERGE dbo.${TABLE_NAME} AS target
USING dbo.${STAGING_TABLE} AS src
ON target.ID = src.ID
WHEN MATCHED THEN
  UPDATE SET
    target.Age = src.Age,
    target.Gender = src.Gender,
    target.Country = src.Country,
    target.Coffee_Intake = src.Coffee_Intake,
    target.Caffeine_mg = src.Caffeine_mg,
    target.Sleep_Hours = src.Sleep_Hours,
    target.Sleep_Quality = src.Sleep_Quality,
    target.BMI = src.BMI,
    target.Heart_Rate = src.Heart_Rate,
    target.Stress_Level = src.Stress_Level,
    target.Physical_Activity_Hours = src.Physical_Activity_Hours,
    target.Health_Issues = src.Health_Issues,
    target.Occupation = src.Occupation,
    target.Smoking = src.Smoking,
    target.Alcohol_Consumption = src.Alcohol_Consumption
WHEN NOT MATCHED THEN
  INSERT (ID, Age, Gender, Country, Coffee_Intake, Caffeine_mg, Sleep_Hours, Sleep_Quality, BMI, Heart_Rate, Stress_Level, Physical_Activity_Hours, Health_Issues, Occupation, Smoking, Alcohol_Consumption)
  VALUES (src.ID, src.Age, src.Gender, src.Country, src.Coffee_Intake, src.Caffeine_mg, src.Sleep_Hours, src.Sleep_Quality, src.BMI, src.Heart_Rate, src.Stress_Level, src.Physical_Activity_Hours, src.Health_Issues, src.Occupation, src.Smoking, src.Alcohol_Consumption);

SELECT COUNT(*) AS row_count FROM dbo.${TABLE_NAME};
SQL

echo "Completed."
echo "SQL server endpoint: $SQL_SERVER_FQDN"
echo "Database/Table: ${DB_NAME}.${TABLE_NAME}"
echo "Storage account: $STORAGE_ACCOUNT_NAME"
