targetScope = 'resourceGroup'

@description('Short suffix used to build resource names. Use lowercase letters and numbers only.')
@minLength(3)
@maxLength(10)
param userInput string

@description('Azure SQL administrator username.')
@minLength(1)
param sqlAdminUsername string

@secure()
@description('Azure SQL administrator password.')
param sqlAdminPassword string

var sqlServerName = take(toLower('sql${userInput}${uniqueString(resourceGroup().id, userInput)}'), 63)
var sqlDatabaseName = 'sqldb${userInput}'
// Storage account names must be lowercase, alphanumeric, and <= 24 characters.
var storageAccountName = take(toLower('stor${userInput}${uniqueString(resourceGroup().id, userInput)}'), 24)

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: resourceGroup().location
  properties: {
    administratorLogin: sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: '1.2'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: resourceGroup().location
  sku: {
    // Basic is the lowest-cost Azure SQL Database compute tier.
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    maxSizeBytes: 2147483648
    zoneRedundant: false
    readScale: 'Disabled'
  }
}

resource sqlFirewallAllowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
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

output sqlServerResourceName string = sqlServer.name
output sqlDatabaseResourceName string = sqlDatabaseName
output sqlServerFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output storageAccountResourceName string = storage.name
