@description('Name of the workspace.')
param workspaceName string

@description('Pricing tier: PerGB2018 or legacy tiers (Free, Standalone, PerNode, Standard or Premium) which are not available to all customers.')
@allowed([
  'pergb2018'
  'Free'
  'Standalone'
  'PerNode'
  'Standard'
  'Premium'
])
param sku string = 'pergb2018'

@description('Specifies the location for the workspace.')
param location string

@description('Number of days to retain data.')
param retentionInDays int = 30

@description('true to use resource or workspace permissions. false to require workspace permissions.')
param resourcePermissions bool

@description('Number of days to retain data in Heartbeat table.')
param heartbeatTableRetention int

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: sku
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: resourcePermissions
    }
  }
}

resource logAnalyticsWorkspaceHeartbeat 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalyticsWorkspace
  name: 'Heartbeat'
  properties: {
    retentionInDays: heartbeatTableRetention
  }
}

output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
