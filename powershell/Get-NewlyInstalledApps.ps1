###############
### Modules ###
###############
Import-Module `
  Az.Accounts, `
  Az.Resources, `
  Az.Storage, `
  Microsoft.Graph.Authentication, `
  Microsoft.Graph.DeviceManagement


##########################
### Imported Functions ###
##########################
Import-Module $PSScriptRoot/BlobStorage.psm1
Import-Module $PSScriptRoot/SendEmail.psm1


#############################
### Environment Variables ###
#############################
# This is how we determine if code is executing in an Azure function, or locally.
# env.psd1 isn't copied in the function deployment package.
# This is block is necessary because Azure uses PSDrive syntax to access environment variables.
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
$Date = Get-Date -Format MMddyyyy
$BlobNameDetectedApps = "detected_apps_${Date}.csv"
$BlobNameNewApps = "new_apps_${Date}.csv"


try {
  # Perform same check on $envFile to determine if we're running in Azure. 
  # Connect-MgGraph command is different if we are.
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
  Remove-OldBlobs -StorageContext $StorageContext -ContainerName $STORAGE_CONTAINER_DETECTED_APPS -OlderThanDays $RETENTION_PERIOD
  Remove-OldBlobs -StorageContext $StorageContext -ContainerName $STORAGE_CONTAINER_NEW_APPS -OlderThanDays $RETENTION_PERIOD

  Write-Host "Retrieving detected apps from Intune."

  $DetectedApps = Get-MgDeviceManagementDetectedApp -All

  if ($DetectedApps.length -eq 0) {
    Write-Host "No detected apps found. Output will be blank."
    
  }

  $FilteredApps = @()

  foreach ($App in $DetectedApps) {
    # Win32/Msi/Msix app IDs are 44 characters long, 
    # MS Store/Universal Windows Platform apps have 64 character IDs.
    if ($App.Id.length -eq 44) {
      $FilteredApps += [PSCustomObject]@{
        "Id"          = $App.Id
        "DisplayName" = $App.DisplayName
        "Publsher"    = $App.Publisher
        "Version"     = $App.Version
      }
    }
  }

  Save-CSVToBlob `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -BlobName $BlobNameDetectedApps `
    -Data $FilteredApps

  $PreviousDetectedApps = Get-CSVFromContainer `
    -StorageContext $StorageContext `
    -ContainerName $STORAGE_CONTAINER_DETECTED_APPS `
    -MostRecent

  if (!$PreviousDetectedApps) {
    Write-Host "No previous apps found, unable to generate diff. Exiting..." -ForegroundColor Red
    exit 1
  }

  # Compare current Intune output to saved output from prior run
  Write-Host "Comparing current detected apps with previous list..."

  $Diff = Compare-Object `
    -ReferenceObject $PreviousDetectedApps `
    -DifferenceObject $FilteredApps `
    -Property DisplayName `
    -PassThru

  if ($Diff) {
    Save-CSVToBlob `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -BlobName $BlobNameNewApps `
      -Data $Diff

  }
  else {
    Write-Host "No new applications found, skipping upload to blob storage."

  }

  # If it's $REPORT_DAY_OF_WEEK, grab the last week's worth of diffs and send the report
  if ((Get-Date).DayOfWeek -eq $REPORT_DAY_OF_WEEK) {

    $NewApps = Get-CSVFromContainer `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -WithinLastDays $DAYS_TO_AGGREGATE

    # Remove duplicate apps
    $NewApps = $NewApps | Sort-Object Id -Unique

    if ($NewApps.length -eq 0) {
      Write-Output "No new applications found in the last $DAYS_TO_AGGREGATE days."
      
      Send-Email `
        -From $EMAIL_FROM `
        -To $EMAIL_TO `
        -Subject 'App detections' `
        -Body "No new applications found in the last $DAYS_TO_AGGREGATE days."
      
      exit 0

    }

    $Results = @()

    foreach ($App in $NewApps) {
      # Filter new apps only
      if ($App.SideIndicator -eq '=>') {
        $Devices = (Get-MgDeviceManagementDetectedAppManagedDevice -DetectedAppId $App.Id).DeviceName -Join ", "

        $Results += [PSCustomObject]@{
          "Application Name" = $App.DisplayName
          "Device(s)"        = $Devices
        }
      }
    }

    # Sort results & format so output isn't truncated
    $Results = $Results | Sort-Object -Property 'Application Name'

    $ResultString = $Results | Format-List -Property 'Application Name', 'Device(s)' | Out-String

    Write-Host "`nResults:`n $ResultString"

    Write-Host "Sending email notice to $EMAIL_TO"

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