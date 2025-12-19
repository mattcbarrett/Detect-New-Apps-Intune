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
  $APPS_TO_IGNORE = $env["APPS_TO_IGNORE"]

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
  $APPS_TO_IGNORE = $env:APPS_TO_IGNORE | ConvertFrom-Json

}

#################
### Constants ###
################# 
$Date = Get-Date -Format yyyyMMdd-HHmmss
$BlobNameDetectedApps = "devices_with_detected_apps_${Date}.json"
$BlobNameNewApps = "devices_with_new_apps_${Date}.json"

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

  # Prune old files before we get started
  Remove-OldBlobs `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -OlderThanDays $RETENTION_PERIOD

  Remove-OldBlobs `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_NEW_APPS `
    -OlderThanDays $RETENTION_PERIOD

  Write-Host "Retrieving detected apps from Intune."

  $AllDevices = Get-MgDeviceManagementManagedDevice -All

  if ($AllDevices.length -eq 0) {

    Write-Host "No devices found in Intune."

    exit 0

  }

  $DevicesWithApps = foreach ($Device in $AllDevices) {

    $DetectedApps = Get-ManagedDeviceDetectedApps -DeviceId $Device.Id |
    Where-Object { 
      $App = $_
      $App.Id.Length -eq 44 -and
      -not ($APPS_TO_IGNORE.Where({ $App.DisplayName -like $_ }, 'First'))
    } |
    ForEach-Object {
      $_.Id = $_.Id -replace ".{4}$"
      $_
    }

    [PSCustomObject]@{
      "Id"           = $Device.Id
      "DeviceName"   = $Device.DeviceName
      "SerialNumber" = $Device.SerialNumber
      "Apps"         = $DetectedApps
    }

    # Rate-limit mitigation
    Start-Sleep -Milliseconds 1150

  }

  Save-Results `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -BlobName $BlobNameDetectedApps `
    -Data $DevicesWithApps

  $PreviousDevicesWithApps = Read-MostRecentResults `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS

  if (!$PreviousDevicesWithApps) {

    Write-Host "No prior detected apps found in container: $STORAGE_CONTAINER_DETECTED_APPS.`nThis is expected on the first run. Exiting."

    exit 0

  }

  # Compare current Intune output to saved output from prior run
  Write-Host "Comparing today's detected apps list with prior run..."

  $Detections = @(

    foreach ($PreviousDevice in $PreviousDevicesWithApps) {

      $ExistingDevice = $DevicesWithApps | Where-Object { $_.Id -eq $PreviousDevice.Id }
      
      if ($ExistingDevice) {

        $PreviousAppsIds = $PreviousDevice.Apps | ForEach-Object { $_.id }

        $NewApps = $ExistingDevice.Apps | Where-Object { $_.Id -notin $PreviousAppsIds }
          
        if ($NewApps) {

          [PSCustomObject]@{
            "Id"           = $ExistingDevice.Id
            "DeviceName"   = $ExistingDevice.DeviceName
            "SerialNumber" = $ExistingDevice.SerialNumber
            "Apps"         = $NewApps
          }

        }

      }

    }

    $NewDevices = $DevicesWithApps | Where-Object { $_.Id -notin $PreviousDevicesWithApps.Id }

    foreach ($Device in $NewDevices) {

      [PSCustomObject]@{
        "Id"           = $ExistingDevice.Id
        "DeviceName"   = $ExistingDevice.DeviceName
        "SerialNumber" = $ExistingDevice.SerialNumber
        "Apps"         = $NewApps
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

    $AggregateResults = Read-AggregateDeviceResults `
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
    $ResultString = $AggregateResults | Format-List -Property 'DeviceName', 'SerialNumber', 'Apps' | Out-String

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