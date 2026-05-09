#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/01_deploy_and_populate.sh <userinput> [location]
# Example: ./scripts/01_deploy_and_populate.sh demo eastus2

USER_INPUT_RAW="${1:-}"
LOCATION="${2:-eastus2}"

if [[ -z "$USER_INPUT_RAW" ]]; then
  echo "Usage: $0 <userinput> [location]"
  echo "Example: $0 demo eastus2"
  exit 1
fi

USER_INPUT="$(echo "$USER_INPUT_RAW" | tr '[:upper:]' '[:lower:]')"
if [[ ! "$USER_INPUT" =~ ^[a-z0-9]+$ ]]; then
  echo "Error: userinput must contain only letters and numbers."
  exit 1
fi

RG_NAME="rg_${USER_INPUT}"
DEPLOYMENT_NAME="deploy-${USER_INPUT}-$(date +%Y%m%d%H%M%S)"
BICEP_FILE="infra/main.bicep"

if [[ ! -f "$BICEP_FILE" ]]; then
  echo "Error: missing Bicep file at $BICEP_FILE"
  exit 1
fi

SQL_ADMIN_USERNAME="${SQL_ADMIN_USERNAME:-${MYSQL_ADMIN_USERNAME:-sqladminuser}}"
SQL_ADMIN_PASSWORD="${SQL_ADMIN_PASSWORD:-${MYSQL_ADMIN_PASSWORD:-}}"
if [[ -z "$SQL_ADMIN_PASSWORD" ]]; then
  # Avoid SIGPIPE (exit 141) from the random-password pipeline when pipefail is enabled.
  set +o pipefail
  GENERATED_PASSWORD="$(tr -dc 'A-Za-z0-9!@#$%^&*()_+=-' </dev/urandom | head -c 24 || true)"
  set -o pipefail

  if [[ -z "$GENERATED_PASSWORD" ]]; then
    GENERATED_PASSWORD="$(date +%s%N | sha256sum | cut -c 1-24)"
  fi

  SQL_ADMIN_PASSWORD="${GENERATED_PASSWORD}Aa1!"
  echo "Generated SQL_ADMIN_PASSWORD for this run."
fi

echo "Deploying Azure resources with userInput=$USER_INPUT in $LOCATION..."
az deployment sub create \
  --name "$DEPLOYMENT_NAME" \
  --location "$LOCATION" \
  --template-file "$BICEP_FILE" \
  --parameters \
    userInput="$USER_INPUT" \
    location="$LOCATION" \
    sqlAdminUsername="$SQL_ADMIN_USERNAME" \
    sqlAdminPassword="$SQL_ADMIN_PASSWORD" >/tmp/az-deploy-output.json

STORAGE_ACCOUNT_NAME="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.storageAccountResourceName.value -o tsv)"
SQL_SERVER_NAME="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.sqlServerResourceName.value -o tsv)"
SQL_SERVER_FQDN="$(az deployment sub show --name "$DEPLOYMENT_NAME" --query properties.outputs.sqlServerFullyQualifiedDomainName.value -o tsv)"
if [[ -z "$STORAGE_ACCOUNT_NAME" ]]; then
  echo "Error: could not determine storage account output from deployment."
  exit 1
fi

if [[ -z "$SQL_SERVER_FQDN" ]]; then
  echo "Error: could not determine Azure SQL server output from deployment."
  exit 1
fi

echo "Storage account deployed: $STORAGE_ACCOUNT_NAME"

ACCOUNT_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
STORAGE_SCOPE="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RG_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"

# Grant the signed-in user data-plane access so upload-batch can run with auth-mode login.
az role assignment create \
  --assignee-object-id "$ACCOUNT_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_SCOPE" >/dev/null 2>&1 || true

upload_folder() {
  local source_dir="$1"
  local container="$2"

  if [[ ! -d "$source_dir" ]]; then
    echo "Warning: source folder not found, skipping: $source_dir"
    return
  fi

  echo "Uploading $source_dir -> container $container"
  az storage blob upload-batch \
    --account-name "$STORAGE_ACCOUNT_NAME" \
    --auth-mode login \
    --destination "$container" \
    --source "$source_dir" \
    --overwrite true
}

upload_folder "data/Coffee/CoffeeHealth" "coffeehealth"
upload_folder "data/Coffee/CoffeeShop" "coffeeshop"
upload_folder "data/Coffee/HealthEffects" "healtheffects"
upload_folder "data/Coffee/CoffeeRecipes" "coffeerecipes"

echo "Deployment and upload complete."
echo "Resource Group: $RG_NAME"
echo "SQL server name: $SQL_SERVER_NAME"
echo "SQL server FQDN: $SQL_SERVER_FQDN"
echo "SQL admin username: $SQL_ADMIN_USERNAME"
echo "SQL admin password: $SQL_ADMIN_PASSWORD"
echo "Storage account: $STORAGE_ACCOUNT_NAME"
