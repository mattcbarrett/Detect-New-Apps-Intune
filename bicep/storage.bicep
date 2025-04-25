param storageAccountName string
param storageContainerName string
param userPrincipalId string
param location string
param keyVaultName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  parent: storageAccount
  name: 'default' // Default name for blobServices in Azure Storage
}

resource storageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  parent: blobService
  name: storageContainerName
  properties: {
    publicAccess: 'None' // Equivalent to `-Permission off`
  }
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(userPrincipalId, storageAccount.id, 'Storage Blob Data Owner')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b') // "Storage Blob Data Owner" role ID
    principalId: userPrincipalId
    principalType: 'User'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [  // allow the deployment principal or function app to write and read
      {
        tenantId: tenant().tenantId
        objectId: userPrincipalId  // your user or service principal deploying the template
        permissions: {
          secrets: [
            'get'
            'list'
            'set'
          ]
        }
      }
    ]
  }
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'azurewebjobsstorage'
  parent: keyVault
  properties: {
    value: storageAccount.listKeys().keys[0].value
  }
}

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
// output connectionString string = storageAccount.listKeys().keys[0].value
output secretUriWithVersion string = secret.properties.secretUriWithVersion
