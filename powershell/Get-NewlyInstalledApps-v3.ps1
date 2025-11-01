###############
### Modules ###
###############
Import-Module `
  Az.Accounts, `
  Az.Resources, `
  Az.Storage, `
  Microsoft.Graph.Authentication, `
  Microsoft.Graph.DeviceManagement, `
  $PSScriptRoot/BlobStorage.psm1, `
  $PSScriptRoot/SendEmail.psm1, `
  $PSScriptRoot/Functions.psm1 `
  -Force

#############################
### Environment Variables ###
#############################
# This is how we determine if code is executing in an Azure function or locally.
# env.psd1 isn't copied in the function deployment package.
# This block is necessary because Azure uses PSDrive syntax to access environment variables.
$EnvFile = Test-Path -Path '.\env.psd1'

if ($EnvFile) {
  $env = Import-PowerShellDataFile -Path '.\env.psd1'
  $EMAIL_FROM = $env["EMAIL_FROM"]
  $EMAIL_TO = $env["EMAIL_TO"]
  $STORAGE_ACCOUNT = $env["STORAGE_ACCOUNT"]
  $STORAGE_CONTAINER_DETECTED_APPS = $env["STORAGE_CONTAINER_DETECTED_APPS"]
  $STORAGE_CONTAINER_NEW_APPS = $env["STORAGE_CONTAINER_NEW_APPS"]
  $REPORT_DAY_OF_WEEK = $env["REPORT_DAY_OF_WEEK"]
  $DAYS_TO_AGGREGATE = $env["DAYS_TO_AGGREGATE"]
  $RETENTION_PERIOD = $env["RETENTION_PERIOD"]

}
else {
  $EMAIL_FROM = $env:EMAIL_FROM
  $EMAIL_TO = $env:EMAIL_TO
  $STORAGE_ACCOUNT = $env:STORAGE_ACCOUNT
  $STORAGE_CONTAINER_DETECTED_APPS = $env:STORAGE_CONTAINER_DETECTED_APPS
  $STORAGE_CONTAINER_NEW_APPS = $env:STORAGE_CONTAINER_NEW_APPS
  $REPORT_DAY_OF_WEEK = $env:REPORT_DAY_OF_WEEK
  $DAYS_TO_AGGREGATE = $env:DAYS_TO_AGGREGATE
  $RETENTION_PERIOD = $env:RETENTION_PERIOD

}

#################
### Constants ###
################# 
$Date = Get-Date -Format yyyyMMdd-HHmmss
$BlobNameDetectedApps = "detected_apps_${Date}.json"
$BlobNameNewApps = "new_apps_${Date}.json"

try {
  # Perform the same check on $EnvFile to determine if we're running in Azure. 
  # Scopes must be specified if so.
  if ($EnvFile) {
    Connect-MgGraph `
      -Scopes "DeviceManagementManagedDevices.Read.All, Mail.Send" `
      -NoWelcome

  }
  else {
    Connect-MgGraph `
      -Identity `
      -NoWelcome

    Write-Host "My MS Graph scopes are: " (Get-MgContext).scopes

  }

  $StorageContext = New-AzStorageContext `
    -StorageAccountName $STORAGE_ACCOUNT `
    -UseConnectedAccount

  # Prune old CSVs before we get started
  Remove-OldBlobs `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -OlderThanDays $RETENTION_PERIOD

  Remove-OldBlobs `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_NEW_APPS `
    -OlderThanDays $RETENTION_PERIOD

  Write-Host "Retrieving detected apps from Intune."

  $AllDetectedApps = Get-MgDeviceManagementDetectedApp -All

  if ($AllDetectedApps.length -eq 0) {
    Write-Host "Intune's detected apps list is empty. Exiting."

    exit 0

  }

  $AllDetectedApps = $AllDetectedApps | Where-Object { $_.Id.Length -eq 44 }

  $DetectedApps = foreach ($App in $AllDetectedApps) {
    # Win32/Msi/Msix app IDs are 44 characters long, 
    # MS Store/Universal Windows Platform apps have 64 character IDs.
    if ($App.Id.length -eq 44) {
      [PSCustomObject]@{
        "Id"          = $App.Id
        "DisplayName" = $App.DisplayName
        "Publisher"   = $App.Publisher
        "Version"     = $App.Version
        "Devices"     = @(
          (Get-DetectedAppManagedDevices -AppId $App.Id).deviceName
        )
      }
    }

    # Rate-limit mitigation
    Start-Sleep -Milliseconds 1150

  }

  Save-Results `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -BlobName $BlobNameDetectedApps `
    -Data $DetectedApps

  $PreviousDetectedApps = Read-MostRecentResults `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS

  if (!$PreviousDetectedApps) {
    Write-Host "No prior detected apps found in container: $STORAGE_CONTAINER_DETECTED_APPS.`nThis is expected on the first run. Exiting."

    exit 0

  }

  # Compare current Intune output to saved output from prior run
  Write-Host "Comparing today's detected apps list with prior run..."

  $Detections = @(
    foreach ($PreviousApp in $PreviousDetectedApps) {
      $DetectedApp = $DetectedApps | Where-Object { $_.Id -eq $PreviousApp.Id }
      
      if ($DetectedApp) {
        $NewDevices = $DetectedApp.Devices | Where-Object { $_ -notin $PreviousApp.Devices }
          
        if ($NewDevices) {
          [PSCustomObject]@{
            "Id"               = $DetectedApp.Id
            "Application Name" = $DetectedApp.DisplayName
            "Version"          = $DetectedApp.Version
            "Devices"          = @($NewDevices) # Needs to become an array
          }
        }
      }


    }

    $NewApps = $DetectedApps | Where-Object { $_.Id -notin $PreviousDetectedApps.Id }

    foreach ($NewApp in $NewApps) {
      [PSCustomObject]@{
        "Id"               = $NewApp.Id
        "Application Name" = $NewApp.DisplayName
        "Version"          = $NewApp.Version
        "Devices"          = $NewApp.Devices # Already an array
      }
    }
  )

  if ($Detections) {
    Save-Results `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -BlobName $BlobNameNewApps `
      -Data $Detections

  }
  else {
    Write-Host "No new apps found, skipping upload to blob storage."

  }

  # If it's $REPORT_DAY_OF_WEEK, grab the last week's worth of diffs and send the report
  if ((Get-Date).DayOfWeek -eq $REPORT_DAY_OF_WEEK) {
    $AggregateResults = Read-AggregateResults `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -DaysToAggregate $DAYS_TO_AGGREGATE

    if ($AggregateResults.length -eq 0) {
      Write-Host "No new apps found in the last $DAYS_TO_AGGREGATE days."
      
      Send-Email `
        -From $EMAIL_FROM `
        -To $EMAIL_TO `
        -Subject 'App detections' `
        -Body "No new apps found in the last $DAYS_TO_AGGREGATE days."
      
      exit 0

    }

    # Format so output isn't truncated
    $ResultString = $AggregateResults | Format-List -Property 'Application Name', 'Version', 'Devices' | Out-String

    Write-Host "`nResults:`n $ResultString"

    Write-Host "Sending email to $EMAIL_TO"

    Send-Email `
      -From $EMAIL_FROM `
      -To $EMAIL_TO `
      -Subject 'App detections' `
      -Body $ResultString

    exit 0

  }
}
catch {
  Write-Output $_

  exit 1

}