targetScope = 'subscription'

@description('Short suffix used to build resource names. Use lowercase letters and numbers only.')
@minLength(3)
@maxLength(10)
param userInput string

@description('Deployment location for the resource group and resources.')
param location string = 'eastus2'

@description('Azure SQL administrator username.')
@minLength(1)
param sqlAdminUsername string

@secure()
@description('Azure SQL administrator password.')
param sqlAdminPassword string

var rgName = 'rg_${userInput}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
}

module workload './resources.bicep' = {
  name: 'workload-${userInput}'
  scope: rg
  params: {
    userInput: userInput
    sqlAdminUsername: sqlAdminUsername
    sqlAdminPassword: sqlAdminPassword
  }
}

output resourceGroupName string = rg.name
output sqlServerResourceName string = workload.outputs.sqlServerResourceName
output sqlServerFullyQualifiedDomainName string = workload.outputs.sqlServerFullyQualifiedDomainName
output storageAccountResourceName string = workload.outputs.storageAccountResourceName
