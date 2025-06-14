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

$storageDeploymentName = "storageDeployment"
$functionAppDeploymentName = "functionAppDeployment"

# Login to Azure
#az login

# Fetch current user's id
$userPrincipalId = az ad signed-in-user show --query id --output tsv

# Create the function app's resources in Azure
$deployment = New-AzDeployment -Location "westus2" -TemplateFile "./bicep/main.bicep" -userPrincipalId $userPrincipalId

# Retrieve outputs from the deployment
$storageOutputs = (Get-AzResourceGroupDeployment -resourceGroupName $deployment.Parameters.resourceGroupName.Value -Name $storageDeploymentName).Outputs
$functionAppOutputs = (Get-AzResourceGroupDeployment -resourceGroupName $deployment.Parameters.resourceGroupName.Value -Name $functionAppDeploymentName).Outputs

# Assign the storage account and container names
$localSettings["Values"]["STORAGE_ACCOUNT"] = $storageOutputs.storageAccountName.Value
$localSettings["Values"]["STORAGE_CONTAINER"] = $storageOutputs.storageContainerName.Value

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

# Push local settings
func azure functionapp publish $functionAppOutputs.functionAppName.Value --publish-local-settings

# Deploy
# func azure functionapp publish $functionAppOutputs.functionAppName.Value