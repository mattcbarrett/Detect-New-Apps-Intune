targetScope = 'subscription'

@description('Path to the abbreviations JSON file')
param abbrs object = loadJsonContent('./abbreviations.json')

param appName string = 'intune-app-detection'
param environmentName string = 'prod'
param location string = 'westus2'
param resourceToken string = substring(toLower(uniqueString(subscription().id, environmentName, location, appName)), 0, 7)
param resourceGroupName string = '${abbrs.resourcesResourceGroups}${appName}-${resourceToken}-${environmentName}'
param storageAccountName string = '${abbrs.storageStorageAccounts}${resourceToken}'
param storageContainerName string = 'detectedapps'
param userPrincipalId string
param functionAppName string = '${abbrs.webSitesFunctions}${appName}-${resourceToken}'
param keyVaultName string = '${abbrs.keyVaultVaults}${resourceToken}'
param appInsightsName string = '${abbrs.insightsComponents}${resourceToken}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

module storage 'storage.bicep' = {
  name: 'storageDeployment'
  scope: resourceGroup
  params: {
    storageAccountName: storageAccountName
    storageContainerName: storageContainerName
    userPrincipalId: userPrincipalId
    location: location
    keyVaultName: keyVaultName
  }
}

module function_app 'function_app.bicep' = {
  name: 'functionAppDeployment'
  scope: resourceGroup
  params: {
    functionAppName: functionAppName
    location: location
    secretUriWithVersion: storage.outputs.secretUriWithVersion
    keyVaultName: keyVaultName
    appInsightsName: appInsightsName
  }
}
