$LocalSettings = @{
  IsEncrypted = $false
  Values      = @{
    FUNCTIONS_WORKER_RUNTIME         = "powershell"
    FUNCTIONS_WORKER_RUNTIME_VERSION = "7.4"
    EMAIL_FROM                       = ""
    EMAIL_TO                         = ""
    STORAGE_ACCOUNT                  = ""
    STORAGE_CONTAINER_DETECTED_APPS  = ""
    STORAGE_CONTAINER_NEW_APPS       = ""
    REPORT_DAY_OF_WEEK               = "Monday"
    DAYS_TO_AGGREGATE                = 7
    RETENTION_PERIOD                 = 14
    APPS_TO_IGNORE                   = (@(
        "Microsoft Office*",
        "Aplikacje Microsoft*",
        "Microsoft 365*",
        "Microsoft OneNote*",
        "Aplicaciones De Microsoft*",
        "Microsoft Visual C++*",
        "Microsoft Edge",
        "Microsoft OneDrive",
        "Microsoft Windows Desktop Runtime*",
        "Microsoft ASP.NET*",
        "Microsoft .NET*",
        "Microsoft Intune Management Extension",
        "Microsoft Support and Recovery Assistant",
        "Microsoft Update Health Tools",
        "Microsoft Teams*",
        "Teams Machine-Wide Installer"
      ) | ConvertTo-Json -Compress)
  }
}

$Constants = Get-Content ./bicep/constants.json | ConvertFrom-Json

# Install necessary apps
winget install -e --id Microsoft.Bicep
winget install -e --id Microsoft.Azure.FunctionsCoreTools

# Reload path so they're available in this session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") `
  + ";" `
  + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Install & import necessary modules
Install-Module Az.Accounts, Az.Resources
Import-Module Az.Accounts, Az.Resources -Force

# Disable login via web acct manager - buggy
Update-AzConfig -EnableLoginByWam $false
Connect-AzAccount

# Fetch current user's id
$UserPrincipalId = (Get-AzContext).Account.ExtendedProperties.HomeAccountId.Split('.')[0]

# Create the function app's resources in Azure
$Deployment = New-AzDeployment `
  -Location "westus2" `
  -TemplateFile "./bicep/main.bicep" `
  -userPrincipalId $UserPrincipalId

# Retrieve outputs from the deployment
$StorageOutputs = (Get-AzResourceGroupDeployment -ResourceGroupName $Deployment.Parameters.resourceGroupName.Value -Name $Constants.storageDeploymentName).Outputs
$FunctionAppOutputs = (Get-AzResourceGroupDeployment -ResourceGroupName $Deployment.Parameters.resourceGroupName.Value -Name $Constants.functionAppDeploymentName).Outputs

# Assign the storage account and container names to local settings
$LocalSettings["Values"]["STORAGE_ACCOUNT"] = $StorageOutputs.storageAccountName.Value
$LocalSettings["Values"]["STORAGE_CONTAINER_DETECTED_APPS"] = $StorageOutputs.storageContainerNameDetectedApps.Value
$LocalSettings["Values"]["STORAGE_CONTAINER_NEW_APPS"] = $StorageOutputs.storageContainerNameNewApps.Value

# Assign MS Graph permissions to the function app's managed identity
# See: https://learn.microsoft.com/en-us/graph/permissions-reference
$MSGraphSPN = Get-AzADServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
$MSGraphPermissionIds = @(
  '2f51be20-0bb4-4fed-bf7b-db946066c75e', # DeviceManagementManagedDevices.Read.All
  'b633e1c5-b582-4048-a93e-9f11b44c7e96' # Mail.Send
)

foreach ($id in $MSGraphPermissionIds) {
  New-AzADServicePrincipalAppRoleAssignment -ServicePrincipalId $FunctionAppOutputs.functionAppPrincipalId.Value -ResourceId $MSGraphSPN.Id -AppRoleId $id
}

# Download modules for the function deployment
New-Item -Path .\function\Modules -ItemType Directory
Save-Module -Name Az.Accounts, Az.Resources, Az.Storage, Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement -Path .\function\Modules

# Copy powershell script & supporting modules to the function app's timer trigger
Copy-Item ".\powershell\Get-NewlyInstalledApps-Mg1.0.ps1", ".\powershell\Functions.psm1", ".\powershell\BlobStorage.psm1", ".\powershell\SendEmail.psm1" -Destination ".\function\TimerTrigger\"

Write-Host "What day of the week should the new app report be sent on? Default: Monday"

do {
  $DayOfWeek = Read-Host -Prompt "Day of week"
  Write-Host ""

  if (!$DayOfWeek) {
    break

  }
  elseif ($DayOfWeek -match "^[a-zA-Z]+$") {
    $LocalSettings["Values"]["REPORT_DAY_OF_WEEK"] = $DayOfWeek
    
    break

  }
  else {
    Write-Host "ERROR: Input value must be a day of the week!" -ForegroundColor Red

  }
} while ($true)

Write-Host "How many days of history should the report aggregate? Default: 7"

do {
  $DaysToAggregate = Read-Host -Prompt "Days"
  Write-Host ""

  if (!$DaysToAggregate) {
    break

  }
  elseif ([int]::TryParse($DaysToAggregate, [ref]$null)) {
    $LocalSettings["Values"]["DAYS_TO_AGGREGATE"] = $DaysToAggregate
    
    break

  }
  else {
    Write-Host "ERROR: Input value must be an integer!" -ForegroundColor Red

  }
} while ($true)

Write-Host "How many days of history should the system retain? Files older than this will be pruned. Default: 14"

do {
  $RetentionPeriod = Read-Host -Prompt "Retention period"
  Write-Host ""

  if (!$RetentionPeriod) {
    break

  }
  elseif ([int]::TryParse($RetentionPeriod, [ref]$null)) {
    $LocalSettings["Values"]["RETENTION_PERIOD"] = $RetentionPeriod

  }
  else {
    Write-Host "ERROR: Input value must be an integer!" -ForegroundColor Red

  }
} while ($true)

Write-Host "Enter the email address of an account to send notices from. Must have an Exchange license."
$EmailFrom = Read-Host -Prompt "Email From"
Write-Host ""

$LocalSettings["Values"]["EMAIL_FROM"] = $EmailFrom

Write-Host "Enter an email address to send notices to."
$EmailTo = Read-Host -Prompt "Email To"
Write-Host ""

$LocalSettings["Values"]["EMAIL_TO"] = $EmailTo

# Write hashtable to json
ConvertTo-Json -InputObject $LocalSettings | Out-File -FilePath .\function\local.settings.json

Set-Location .\function

# Retrieve access token for core tools
# This is to avoid a bug I've encountered with core tools failing
# to retrieve a token on it's own, even though it runs the same commands
$CurrentAzureContext = Get-AzContext
$AzureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$ProfileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient $AzureRmProfile

# Deploy with local settings
func azure functionapp publish $FunctionAppOutputs.functionAppName.Value `
  --publish-local-settings `
  --access-token $($ProfileClient.AcquireAccessToken($CurrentAzureContext.Subscription.TenantId).AccessToken)