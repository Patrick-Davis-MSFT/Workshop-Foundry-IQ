targetScope = 'resourceGroup'

@description('Short suffix used to build resource names. Use lowercase letters and numbers only.')
@minLength(3)
@maxLength(10)
param userInput string

@description('MySQL administrator username.')
@minLength(1)
param mysqlAdminUsername string

@secure()
@description('MySQL administrator password.')
param mysqlAdminPassword string

var mysqlServerName = 'mysql${userInput}'
// Storage account names must be lowercase, alphanumeric, and <= 24 characters.
var storageAccountName = take(toLower('stor${userInput}${uniqueString(resourceGroup().id, userInput)}'), 24)

resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2023-12-30' = {
  name: mysqlServerName
  location: resourceGroup().location
  sku: {
    // Burstable B1ms is typically the lowest-cost generally available compute tier.
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    // eastus2 supports version literal "8.4" (not "8.4.3"); this is the newer LTS line.
    version: '8.4'
    administratorLogin: mysqlAdminUsername
    administratorLoginPassword: mysqlAdminPassword
    storage: {
      storageSizeGB: 20
      iops: 360
      autoGrow: 'Disabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    accessTier: 'Hot'
  }
}

resource coffeeHealthContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: '${storage.name}/default/coffeehealth'
}

resource coffeeShopContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: '${storage.name}/default/coffeeshop'
}

resource healthEffectsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: '${storage.name}/default/healtheffects'
}

resource coffeeRecipesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  name: '${storage.name}/default/coffeerecipes'
}

output mysqlServerResourceName string = mysqlServer.name
output storageAccountResourceName string = storage.name
