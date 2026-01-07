targetScope = 'subscription'

@description('Path to the abbreviations JSON file')
param abbrs object = loadJsonContent('./abbreviations.json')

@description('Constants')
param constants object = loadJsonContent('./constants.json')

param appName string = '${constants.appName}'
param environmentName string = '${constants.environmentName}'
param location string = '${constants.location}'
param resourceToken string = substring(
  toLower(uniqueString(subscription().id, environmentName, location, appName)),
  0,
  7
)
param resourceGroupName string = '${abbrs.resourcesResourceGroups}${appName}-${resourceToken}-${environmentName}'
param storageAccountName string = '${abbrs.storageStorageAccounts}${resourceToken}'
param storageContainerNameDetectedApps string = '${constants.storageContainerNameDetectedApps}'
param storageContainerNameNewApps string = '${constants.storageContainerNameNewApps}'
param functionDeploymentContainerName string = '${abbrs.webSitesFunctions}${appName}-${resourceToken}'
param functionAppName string = '${abbrs.webSitesFunctions}${appName}-${resourceToken}'
param appInsightsName string = '${abbrs.insightsComponents}${resourceToken}'
param userPrincipalId string

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

module logs 'logs.bicep' = {
  name: '${constants.logsAnalyticsDeploymentName}'
  scope: resourceGroup
  params: {
    workspaceName: '${appName}-${resourceToken}-logs'
    location: location
    resourcePermissions: true
    heartbeatTableRetention: 30
  }
}

module storage 'storage.bicep' = {
  name: '${constants.storageDeploymentName}'
  scope: resourceGroup
  params: {
    storageAccountName: storageAccountName
    storageContainerNameDetectedApps: storageContainerNameDetectedApps
    storageContainerNameNewApps: storageContainerNameNewApps
    location: location
    logAnalyticsWorkspaceId: logs.outputs.logAnalyticsWorkspaceId
    functionDeploymentContainerName: functionDeploymentContainerName
  }
}

module function_app 'function_app.bicep' = {
  name: '${constants.functionAppDeploymentName}'
  scope: resourceGroup
  params: {
    functionAppName: functionAppName
    location: location
    storageAccountName: storageAccountName
    appInsightsName: appInsightsName
    logAnalyticsWorkspaceId: logs.outputs.logAnalyticsWorkspaceId
    functionDeploymentContainerName: functionDeploymentContainerName
  }
  dependsOn: [storage]
}

module roles 'roles.bicep' = {
  name: '${constants.rolesDeploymentName}'
  scope: resourceGroup
  params: {
    userPrincipalId: userPrincipalId
    functionAppPrincipalId: function_app.outputs.functionAppPrincipalId
    storageAccountName: storageAccountName
  }
  dependsOn: [storage]
}
