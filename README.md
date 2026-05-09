# Workshop Foundry AI

## Deploy And Populate Data

This repository includes:
- Bicep templates in `infra/`
- Deployment and data upload script in `scripts/01_deploy_and_populate.sh`

### Prerequisites

- Azure CLI installed
- Authenticated session (already done):

```bash
az login --use-device-code
```

### Run Instructions

1. From the repository root, make sure the script is executable:

```bash
chmod +x scripts/01_deploy_and_populate.sh
```

2. Run deployment + data upload (recommended: provide MySQL admin credentials):

```bash
MYSQL_ADMIN_USERNAME=mysqladmin \
MYSQL_ADMIN_PASSWORD='YourStrongPassword123!' \
./scripts/01_deploy_and_populate.sh <userinput> eastus2
```

Example:

```bash
MYSQL_ADMIN_USERNAME=mysqladmin \
MYSQL_ADMIN_PASSWORD='YourStrongPassword123!' \
./scripts/01_deploy_and_populate.sh demo eastus2
```

If `MYSQL_ADMIN_PASSWORD` is omitted, the script generates one and prints it at the end.

### What Gets Created

- Resource group: `rg_<userinput>` in `eastus2`
- MySQL Flexible Server: `mysql<userinput>`
- Storage account: `stor<userinput><randomcode>`
- Blob containers:
  - `coffeehealth`
  - `coffeeshop`
  - `healtheffects`
  - `coffeerecipes`

### Data Upload Mapping

The script uploads these folders to matching containers:

- `data/Coffee/CoffeeHealth` -> `coffeehealth`
- `data/Coffee/CoffeeShop` -> `coffeeshop`
- `data/Coffee/HealthEffects` -> `healtheffects`
- `data/Coffee/CoffeeRecipes` -> `coffeerecipes`

## Create CoffeeHealth Table In MySQL

Use the script below to create a MySQL table and load `synthetic_coffee_health_10000.csv` from blob container `coffeehealth`.

### MySQL Firewall Prerequisite

Before running the `02_` script, allow your current client IP through the MySQL Flexible Server firewall.

```bash
az mysql flexible-server firewall-rule create \
  --resource-group rg_<userinput> \
  --name mysql<userinput> \
  --rule-name allow-current-ip \
  --start-ip-address $(curl -s https://api.ipify.org) \
  --end-ip-address $(curl -s https://api.ipify.org)
```

If you are running inside a dev container, use the public IP of the host/network that reaches Azure.

### Run Script 02

1. Make sure the script is executable:

```bash
chmod +x scripts/02_create_coffeehealth_table.sh
```

2. Run with explicit values (non-interactive):

```bash
./scripts/02_create_coffeehealth_table.sh mysqlpcddemo.mysql.database.azure.com mysqladmin 'YourStrongPassword123!'
```

3. Or run interactively (prompts for missing endpoint/username/password):

```bash
./scripts/02_create_coffeehealth_table.sh
```

```bash
./scripts/02_create_coffeehealth_table.sh [mysql-endpoint] [mysql-username] [mysql-password]
```

Optional environment variables:

- `MYSQL_ENDPOINT`
- `MYSQL_ADMIN_USERNAME`
- `MYSQL_ADMIN_PASSWORD`
- `STORAGE_ACCOUNT_NAME`

If MySQL endpoint, username, or password are missing, the script prompts for them.
