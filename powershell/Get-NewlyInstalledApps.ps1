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
# If statement is how we determine if we're running in an Az function or locally,
# env.psd1 shouldn't be present in the function deployment package.
# Local environment and Azure use different syntax.
$EnvFile = Test-Path -Path '.\env.psd1'

if ($EnvFile) {
  $env = Import-PowerShellDataFile -Path '.\env.psd1'
  $EMAIL_FROM = $env["EMAIL_FROM"]
  $EMAIL_TO = $env["EMAIL_TO"]
  $STORAGE_ACCOUNT = $env["STORAGE_ACCOUNT"]
  $STORAGE_CONTAINER_DETECTED_APPS = $env["STORAGE_CONTAINER_DETECTED_APPS"]
  $STORAGE_CONTAINER_NEW_APPS = $env["STORAGE_CONTAINER_NEW_APPS"]
  $REPORT_DAY_OF_WEEK = $env["REPORT_DAY_OF_WEEK"]
} else {
  $EMAIL_FROM = $env:EMAIL_FROM
  $EMAIL_TO = $env:EMAIL_TO
  $STORAGE_ACCOUNT = $env:STORAGE_ACCOUNT
  $STORAGE_CONTAINER_DETECTED_APPS = $env:STORAGE_CONTAINER_DETECTED_APPS
  $STORAGE_CONTAINER_NEW_APPS = $env:STORAGE_CONTAINER_NEW_APPS
  $REPORT_DAY_OF_WEEK = $env:REPORT_DAY_OF_WEEK
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
  } else {
    Connect-MgGraph `
      -NoWelcome `
      -Identity

    Write-Host "My MS Graph scopes are: " (Get-MgContext).scopes
  }

  $StorageContext = New-AzStorageContext `
    -StorageAccountName $STORAGE_ACCOUNT `
    -UseConnectedAccount

  Write-Host "Retrieving detected apps from Intune."

  $DetectedApps = Get-MgDeviceManagementDetectedApp -All

  if ($DetectedApps.length -eq 0) {
    Write-Host "No detected apps found. Output will be blank."
  }

  $FilteredApps = @()

  foreach ($App in $DetectedApps) {
    # MS Store/Universal Windows Platform apps seem to have 64 char Ids, while Win32/Msi/Msix app Ids seem to be 44 chars.
    if ($App.Id.length -eq 44) {
      $FilteredApps += [PSCustomObject]@{
        "Id" = $App.Id
        "DisplayName" = $App.DisplayName
        "Publsher" = $App.Publisher
        "Version" = $App.Version
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

  # Compare current Intune output to previous
  Write-Host "Comparing current detected apps with previous list..."
  $Diff = Compare-Object -ReferenceObject $PreviousDetectedApps -DifferenceObject $FilteredApps -Property DisplayName -PassThru

  if ($Diff) {
    Save-CSVToBlob `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -BlobName $BlobNameNewApps `
      -Data $Diff
  } else {
    Write-Host "No new applications found, skipping upload to blob storage."
  }

  # If it's $REPORT_DAY_OF_WEEK, grab the last week's worth of diffs and send the report
  if ((Get-Date).DayOfWeek -eq $REPORT_DAY_OF_WEEK) {

    $NewApps = Get-CSVFromContainer `
      -StorageContext $StorageContext `
      -ContainerName $STORAGE_CONTAINER_NEW_APPS `
      -WithinLastDays 7

    # Remove duplicate apps
    $NewApps = $NewApps | Sort-Object Id -Unique

    if ($NewApps.length -eq 0) {
      Write-Output "No new applications found in the last 7 days."
      
      Send-Email `
        -From $EMAIL_FROM `
        -To $EMAIL_TO `
        -Subject 'App detections' `
        -Body "No new applications found in the last 7 days."
      
      exit 0
    }

    # Create list of new & removed apps
    $Results = @()

    foreach ($Item in $NewApps) {
      if ($Item.SideIndicator -eq '=>') {  # Filter new apps only

        # Get the devices that have the newly detected app installed
        $Devices = (Get-MgDeviceManagementDetectedAppManagedDevice -DetectedAppId $item.Id).DeviceName -Join ", "

        # Add results to array
        $Results += [PSCustomObject]@{
          "Application Name" = $Item.DisplayName
          "Device(s)" = $Devices
        }
      }
    }

    # Sort results by app name
    $Results = $Results | Sort-Object -Property 'Application Name'
    $ResultString = $Results | Out-String

    # Print results to console
    Write-Host "`nResults:`n $ResultString"

    # Send email notice
    Write-Host "Sending email notice to $EMAIL_TO"
    Send-Email `
      -From $EMAIL_FROM `
      -To $EMAIL_TO `
      -Subject 'App detections' `
      -Body "$DiffDates`n$ResultString"

    # Print results to terminal
    Write-Output $Results
    exit 0
  }
}
catch {
  Write-Output $_
  exit 1
}