param storageAccountName string
param storageContainerNameDetectedApps string
param storageContainerNameNewApps string
param location string
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
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    encryption: {
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
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
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
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

// These are necessary for deploy.ps1 script to populate env vars in azure.
output storageAccountName string = storageAccount.name
output storageContainerNameDetectedApps string = storageContainerDetectedApps.name
output storageContainerNameNewApps string = storageContainerNewApps.name
