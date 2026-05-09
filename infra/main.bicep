targetScope = 'subscription'

@description('Short suffix used to build resource names. Use lowercase letters and numbers only.')
@minLength(3)
@maxLength(10)
param userInput string

@description('Deployment location for the resource group and resources.')
param location string = 'eastus2'

@description('MySQL administrator username.')
@minLength(1)
param mysqlAdminUsername string

@secure()
@description('MySQL administrator password.')
param mysqlAdminPassword string

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
    mysqlAdminUsername: mysqlAdminUsername
    mysqlAdminPassword: mysqlAdminPassword
  }
}

output resourceGroupName string = rg.name
output mysqlServerResourceName string = workload.outputs.mysqlServerResourceName
output storageAccountResourceName string = workload.outputs.storageAccountResourceName
