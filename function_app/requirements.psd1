# This file enables modules to be automatically managed by the Functions service.
# See https://aka.ms/functionsmanageddependency for additional information.
#
@{
    # For latest supported version, go to 'https://www.powershellgallery.com/packages/Az'. 
    # To use the Az module in your function app, please uncomment the line below.
    # 'Az' = '13.*'
    'Az.Accounts' = '4.*'
    'Az.Resources' = '7.*'
    'Az.Storage' = '8.*'
    'Microsoft.Graph.Authentication' = '2.*'
    'Microsoft.Graph.DeviceManagement' = '2.*'
}