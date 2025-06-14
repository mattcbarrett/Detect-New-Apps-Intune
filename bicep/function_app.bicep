@description('Name of the Function App')
param functionAppName string

@description('Location for all resources')
param location string

@description('Runtime stack (e.g., dotnet, node, python)')
param runtime string = 'powershell'

@description('Runtime version')
param runtime_version string = '7.4'

param storageAccountName string
param appInsightsName string
param logAnalyticsWorkspaceId string
param functionDeploymentContainerName string

var appServicePlanName = '${functionAppName}-plan'

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccountName
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storageAccountName}.blob.core.windows.net/${functionDeploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 4096
      }
      runtime: {
        name: runtime
        version: runtime_version
      }
    }
    httpsOnly: true
  }
}

resource corsSettings 'Microsoft.Web/sites/config@2022-03-01' = {
  name: 'web'
  parent: functionApp
  properties: {
    cors: {
      allowedOrigins: [
        'https://portal.azure.com'
      ]
      supportCredentials: false
    }
  }
}

output functionAppEndpoint string = 'https://${functionApp.name}.azurewebsites.net'
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppName string = functionApp.name
