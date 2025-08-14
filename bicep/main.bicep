targetScope = 'subscription'

@description('Path to the abbreviations JSON file')
param abbrs object = loadJsonContent('./abbreviations.json')

param appName string = 'intune-app-detection'
param environmentName string = 'prod'
param location string = 'westus2'
param resourceToken string = substring(toLower(uniqueString(subscription().id, environmentName, location, appName)), 0, 7)
param resourceGroupName string = '${abbrs.resourcesResourceGroups}${appName}-${resourceToken}-${environmentName}'
param storageAccountName string = '${abbrs.storageStorageAccounts}${resourceToken}'
param storageContainerNameDetectedApps string = 'detectedapps'
param storageContainerNameNewApps string = 'newapps'
param functionDeploymentContainerName string = '${abbrs.webSitesFunctions}${appName}-${resourceToken}'
param userPrincipalId string
param functionAppName string = '${abbrs.webSitesFunctions}${appName}-${resourceToken}'
// param keyVaultName string = '${abbrs.keyVaultVaults}${resourceToken}'
param appInsightsName string = '${abbrs.insightsComponents}${resourceToken}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

module logs 'logs.bicep' = {
 name: 'logAnalyticsDeployment'
 scope: resourceGroup
 params: {
  workspaceName:'${appName}-${resourceToken}-logs'
  location: location
  resourcePermissions: true
  heartbeatTableRetention: 30
 }
}

module storage 'storage.bicep' = {
  name: 'storageDeployment'
  scope: resourceGroup
  params: {
    storageAccountName: storageAccountName
    storageContainerNameDetectedApps: storageContainerNameDetectedApps
    storageContainerNameNewApps: storageContainerNameNewApps
    userPrincipalId: userPrincipalId
    location: location
    functionAppPrincipalId: function_app.outputs.functionAppPrincipalId
    logAnalyticsWorkspaceId: logs.outputs.logAnalyticsWorkspaceId
    functionDeploymentContainerName: functionDeploymentContainerName
  }
}


module function_app 'function_app.bicep' = {
  name: 'functionAppDeployment'
  scope: resourceGroup
  params: {
    functionAppName: functionAppName
    location: location
    storageAccountName: storageAccountName
    appInsightsName: appInsightsName
    logAnalyticsWorkspaceId: logs.outputs.logAnalyticsWorkspaceId
    functionDeploymentContainerName: functionDeploymentContainerName
  }
}

