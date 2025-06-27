$localSettings = @{
  IsEncrypted = $false
  Values = @{
    FUNCTIONS_WORKER_RUNTIME = "powershell"
    FUNCTIONS_WORKER_RUNTIME_VERSION = "7.4"
    MIN_AGE = 4
    EMAIL_FROM = ""
    EMAIL_TO = ""
    STORAGE_ACCOUNT = ""
    STORAGE_CONTAINER = ""
  }
}

# Deployment names from bicep/main.bicep
$storageDeploymentName = "storageDeployment"
$functionAppDeploymentName = "functionAppDeployment"

# Login to Azure
Connect-AzAccount

# Fetch current user's id
$userPrincipalId = (Get-AzContext).Account.ExtendedProperties.HomeAccountId.Split('.')[0]

# Create the function app's resources in Azure
$deployment = New-AzDeployment -Location "westus2" -TemplateFile "./bicep/main.bicep" -userPrincipalId $userPrincipalId

# Retrieve outputs from the deployment
$storageOutputs = (Get-AzResourceGroupDeployment -resourceGroupName $deployment.Parameters.resourceGroupName.Value -Name $storageDeploymentName).Outputs
$functionAppOutputs = (Get-AzResourceGroupDeployment -resourceGroupName $deployment.Parameters.resourceGroupName.Value -Name $functionAppDeploymentName).Outputs

# Assign the storage account and container names to local settings
$localSettings["Values"]["STORAGE_ACCOUNT"] = $storageOutputs.storageAccountName.Value
$localSettings["Values"]["STORAGE_CONTAINER"] = $storageOutputs.storageContainerName.Value

# Assign MS Graph permissions to the function app's managed identity
# See: https://learn.microsoft.com/en-us/graph/permissions-reference
$msGraphSPN = Get-AzADServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$msGraphPermissionIds = @(
  '2f51be20-0bb4-4fed-bf7b-db946066c75e', # DeviceManagementManagedDevices.Read.All
  'b633e1c5-b582-4048-a93e-9f11b44c7e96' # Mail.Send
)

foreach ($id in $msGraphPermissionIds) {
  New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $functionAppOutputs.functionAppPrincipalId.Value -ResourceId $msGraphSPN.Id -AppRoleId $id
}

# Download modules for the function deployment
New-Item -Path .\function\Modules -ItemType Directory
Save-Module -Name Az.Accounts, Az.Resources, Az.Storage, Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement -Path .\function\Modules

# Copy powershell script & supporting modules to the function app's timer trigger
Copy-Item .\powershell\Get-NewlyInstalledApps.ps1, .\powershell\BlobStorage.psm1, .\powershell\SendEmail.psm1 -Destination .\function\TimerTrigger\

# Collect environment variables from the user
Write-Host "Enter the delta, in days, to report app detections for. Default: 4 days."
$minAge = Read-Host -Prompt "Days"
Write-Host ""

# Write-Host "Enter the email address of the account to send notices from. Must have an Exchange license."
$emailFrom = Read-Host -Prompt "Email From"
Write-Host ""

# Write-Host "Enter the email address to send notices to."
$emailTo = Read-Host -Prompt "Email To"
Write-Host ""

# Write vars into hashtable
if ($minAge) {
  $localSettings["Values"]["MIN_AGE"] = $minAge
}
$localSettings["Values"]["EMAIL_FROM"] = $emailFrom
$localSettings["Values"]["EMAIL_TO"] = $emailTo

# Write hashtable to json
ConvertTo-Json -InputObject $localSettings | Out-File -FilePath .\function\local.settings.json

# cd to function dir
Set-Location .\function

# Deploy with local settings
func azure functionapp publish $functionAppOutputs.functionAppName.Value --publish-local-settings