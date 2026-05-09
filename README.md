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
