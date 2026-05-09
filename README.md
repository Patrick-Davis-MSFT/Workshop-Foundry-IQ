# Workshop Foundry AI

## Overview

This repository contains:
- Infrastructure as code in `infra/`
- Deployment and blob upload script in `scripts/01_deploy_and_populate.sh`
- CoffeeHealth SQL load script in `scripts/02_create_coffeehealth_table.sh`
- CoffeeShop relational SQL load script in `scripts/03_load_coffeeshop_tables.sh`

The solution now uses Azure SQL Database (not MySQL).

## Prerequisites

- Azure CLI installed
- Authenticated Azure session:

```bash
az login --use-device-code
```

- SQL command-line tools installed:
  - `sqlcmd`
  - `bcp`

If you are using this repository in the dev container, these tools are installed by `.devcontainer/devcontainer.json` during container setup.

## Script 01: Deploy Infrastructure And Upload Data

Script:

```bash
./scripts/01_deploy_and_populate.sh <userinput> [location]
```

Example:

```bash
SQL_ADMIN_USERNAME=sqladminuser \
SQL_ADMIN_PASSWORD='YourStrongPassword123!' \
./scripts/01_deploy_and_populate.sh demo eastus2
```

If `SQL_ADMIN_PASSWORD` is omitted, the script generates one and prints it.

### What Script 01 Creates

- Resource group: `rg_<userinput>` in `eastus2` (or provided location)
- Azure SQL logical server: `sql<userinput><randomcode>`
- Azure SQL database: `sqldb<userinput>`
  - SKU: Basic (lowest-cost Azure SQL tier)
  - Max size: 2 GB
- Storage account: `stor<userinput><randomcode>`
- Blob containers:
  - `coffeehealth`
  - `coffeeshop`
  - `healtheffects`
  - `coffeerecipes`

### Data Upload Mapping (Script 01)

- `data/Coffee/CoffeeHealth` -> `coffeehealth`
- `data/Coffee/CoffeeShop` -> `coffeeshop`
- `data/Coffee/HealthEffects` -> `healtheffects`
- `data/Coffee/CoffeeRecipes` -> `coffeerecipes`

## Azure SQL Firewall Prerequisite

Before running scripts `02_` or `03_`, allow your client IP through the Azure SQL firewall.

```bash
az sql server firewall-rule create \
  --resource-group rg_<userinput> \
  --server <sql-server-name> \
  --name allow-current-ip \
  --start-ip-address $(curl -s https://api.ipify.org) \
  --end-ip-address $(curl -s https://api.ipify.org)
```

Notes:
- `<sql-server-name>` is the SQL server name printed by script `01_`.
- If using a dev container, use the public IP that Azure sees from your host/network.

## Script 02: Load CoffeeHealth CSV Into Azure SQL

Script:

```bash
./scripts/02_create_coffeehealth_table.sh [sql-server-fqdn] [sql-admin-username] [sql-admin-password] [database-name]
```

Examples:

```bash
# Non-interactive
./scripts/02_create_coffeehealth_table.sh sqlabc123.database.windows.net sqladminuser 'YourStrongPassword123!' coffee_health

# Interactive prompts for missing values
./scripts/02_create_coffeehealth_table.sh
```

Optional environment variables:

- `SQL_SERVER_FQDN`
- `SQL_ADMIN_USERNAME`
- `SQL_ADMIN_PASSWORD`
- `SQL_DATABASE`
- `STORAGE_ACCOUNT_NAME`

Behavior:
- Downloads `synthetic_coffee_health_10000.csv` from blob container `coffeehealth`
- Loads to staging table with `bcp`
- Uses SQL `MERGE` into target table for idempotent reruns (no duplicate rows by `ID`)

## Script 03: Load CoffeeShop Relational Dataset Into Azure SQL

Script:

```bash
./scripts/03_load_coffeeshop_tables.sh [sql-server-fqdn] [sql-admin-username] [sql-admin-password] [database-name]
```

Examples:

```bash
# Non-interactive
./scripts/03_load_coffeeshop_tables.sh sqlabc123.database.windows.net sqladminuser 'YourStrongPassword123!' coffee_shop

# Interactive prompts for missing values
./scripts/03_load_coffeeshop_tables.sh
```

Optional environment variables:

- `SQL_SERVER_FQDN`
- `SQL_ADMIN_USERNAME`
- `SQL_ADMIN_PASSWORD`
- `SQL_DATABASE`
- `COFFEESHOP_DATA_ROOT`

Behavior:
- Concatenates monthly CSV files for `users`, `transactions`, and `transaction_items`
- Loads all source CSVs into staging tables via `bcp`
- Upserts into final tables with `MERGE`
- Preserves/reuses PK/FK relationships
- Idempotent on reruns (no duplicate inserts)

## Quick Run Order

1. Run script `01_` to deploy Azure SQL + Storage and upload data to blob.
2. Add Azure SQL firewall rule for your current IP.
3. Run script `02_` to load CoffeeHealth table.
4. Run script `03_` to load CoffeeShop relational tables.
