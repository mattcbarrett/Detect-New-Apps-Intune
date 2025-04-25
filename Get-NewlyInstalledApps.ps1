# Import modules
Import-Module `
  Az.Accounts, `
  Az.Resources, `
  Az.Storage, `
  Microsoft.Graph.Authentication, `
  Microsoft.Graph.DeviceManagement

# Import "env" file
$env = Import-PowerShellDataFile -Path '.\env.psd1'
$MIN_AGE = $env["MIN_AGE"]
$EMAIL_FROM = $env["EMAIL_FROM"]
$EMAIL_TO = $env["EMAIL_TO"]
$STORAGE_ACCOUNT = $env["STORAGE_ACCOUNT"]
$STORAGE_CONTAINER = $env["STORAGE_CONTAINER"]

# Import functions
Import-Module .\BlobStorage.psm1
Import-Module .\SendEmail.psm1

# Define variables
$date = Get-Date -Format MMddyyyy
$blobName = "detected_apps_${date}.csv"

try {
  # Connect to MS Graph so we can pull device & software information
  Connect-MgGraph `
    -Scopes "DeviceManagementManagedDevices.Read.All, Mail.Send" `
    -NoWelcome

  # Create a storage context
  $storageContext = New-AzStorageContext `
    -StorageAccountName $STORAGE_ACCOUNT `
    -UseConnectedAccount

  # Fetch detected apps from Intune
  Write-Host "Retrieving detected apps from Intune."
  $mgGraphDetectedApps = Get-MgDeviceManagementDetectedApp -All

  # Error handling
  if ($mgGraphDetectedApps.length -eq 0) {
    Write-Host "No detected apps found. Output will be blank."
  }

  # Empty array for results
  $currentDetectedApps = @()

  # MS Store/UWP apps seem to have 64 char Ids, while Win32/Msi/Msix app Ids seem to be 44 chars. Lose the if statement below or switch to "-gt > 0" to return ALL apps.
  foreach ($app in $mgGraphDetectedApps) {
    if ($app.Id.length -eq 44) {
      $currentDetectedApps += [PSCustomObject]@{
        "Id" = $app.Id
        "DisplayName" = $app.DisplayName
        "Publsher" = $app.Publisher
        "Version" = $app.Version
      }
    }
  }

  # Sort by name
  $currentDetectedApps = $currentDetectedApps | Sort-Object -Property DisplayName

  # Write current list of apps to storage for next run
  $body = ($currentDetectedApps | ConvertTo-Csv -NoTypeInformation) -join "`n"

  $writeResult = Write-Blob `
    -storageContext $storageContext `
    -storageContainer $STORAGE_CONTAINER `
    -blobName $blobName `
    -body $body `
    -ContentType "text/csv;charset=utf-8"

  if ($writeResult.StatusCode -eq "201") {
    Write-Host "Saved detected apps to $STORAGE_CONTAINER\$blobName."
  } else {
    throw "Unable to save detected apps to $STORAGE_CONTAINER\$blobName."
  }

  # Now we retrieve a list from a prior run from Azure Storage.
  # Start by listing all blobs in the container
  Write-Host "Retrieving previously detected apps from blob storage. Filtering for files older than $MIN_AGE days."
  $xml = Get-Blobs -storageContext $storageContext -storageContainer $STORAGE_CONTAINER
  $blobs = $xml.enumerationResults.blobs.blob

  $filteredBlobs = @()

  foreach ($blob in $blobs) {
    # Cast the blob's Creation-Time property from string to DateTime
    [DateTime]$creationTime = $blob.properties.'Creation-Time'
    $today = Get-Date

    # Filter blobs <= $MIN_AGE
    if ($creationTime -le $today.AddDays(-$MIN_AGE)) {
      $filteredBlobs += [PSCustomObject]@{
        "Name" = $blob.Name
        "Creation-Time" = $creationTime
      }
    }
  }

  # Error handling
  if ($filteredBlobs.length -eq 0) {
    throw "No blobs found older than $MIN_AGE days. Try adjusting the MIN_AGE variable."
  }

  $filteredBlobs = $filteredBlobs | Sort-Object -Property 'Creation-Time' -Descending

  $latestBlob = $filteredBlobs[0]

  Write-Host "Selected file $($latestBlob.name)."

  # Retrieve the CSV from storage blob
  $previousDetectedApps = Read-Blob `
    -storageContext $storageContext `
    -storageContainer $STORAGE_CONTAINER `
    -blobName $latestBlob.Name

  if ($previousDetectedApps) {
    Write-Host "Retrieved file $($latestBlob.name)."
  } else {
    throw "Retrieving file $($latestBlob.name) failed."
  }

  # Convert from csv to powershell object
  $previousDetectedApps = $previousDetectedApps | ConvertFrom-Csv

  # Create the diff
  $diffDates = "Generated diff between apps detected on $($latestBlob.'Creation-Time') and $(Get-Date)."
  Write-Host $diffDates

  # diffit!
  $diff = Compare-Object `
    -ReferenceObject $previousDetectedApps `
    -DifferenceObject $currentDetectedApps `
    -Property DisplayName `
    -PassThru

  # Create list of new & removed apps for $interval
  $results = @()

  foreach ($item in $diff) {
    if ($item.SideIndicator -eq '=>') {  # Filter new apps only

      # Get the devices that have the newly detected app installed
      $devices = (Get-MgDeviceManagementDetectedAppManagedDevice -DetectedAppId $item.Id).DeviceName -Join ", "

      # Add results to array
      $results += [PSCustomObject]@{
        "Application Name" = $item.DisplayName
        "Device(s)" = $devices
      }
    }
  }

  # Sort results by app name
  $results = $results | Sort-Object -Property 'Application Name'
  $resultString = $results | Out-String

  # Send email notice
  Write-Host "Sending email notice to $EMAIL_TO"
  Send-Email -From $EMAIL_FROM -To $EMAIL_TO -Subject 'App detections' -Body "$diffDates`n$resultString"

  # Print results to terminal
  Write-Output $results
  exit 0
}
catch {
  Write-Output $_
  exit 1
}