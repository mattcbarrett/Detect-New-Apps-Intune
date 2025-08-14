param storageAccountName string
param storageContainerNameDetectedApps string
param storageContainerNameNewApps string
param userPrincipalId string
param location string
param functionAppPrincipalId string
param logAnalyticsWorkspaceId string
param functionDeploymentContainerName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  parent: storageAccount
  name: 'default'
}

resource storageContainerDetectedApps 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: storageContainerNameDetectedApps
  properties: {
    publicAccess: 'None'
  }
}

resource storageContainerNewApps 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: storageContainerNameNewApps
  properties: {
    publicAccess: 'None'
  }
}

resource functionDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: functionDeploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource storageDataPlaneLogs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-logs'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'StorageWrite'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource roleAssignmentUserPrincipalId 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(userPrincipalId, storageAccount.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b') // "Storage Blob Data Owner" role ID
    principalId: userPrincipalId
    principalType: 'User'
  }
}

resource roleAssignmentFunctionAppManagedId 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionAppPrincipalId, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: functionAppPrincipalId
  }
}

output storageAccountName string = storageAccount.name
output storageContainerNameDetectedApps string = storageContainerDetectedApps.name
output storageContainerNameNewApps string = storageContainerNewApps.name
