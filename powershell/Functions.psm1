function Save-Results {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][String]$ContainerName,
    [Parameter(Mandatory = $true)][String]$BlobName,
    [Parameter(Mandatory = $true)]$Data
  )

  $Body = $Data | ConvertTo-Json
  $ContentType = "text/json"

  $Result = Write-Blob `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName `
    -BlobName $BlobName `
    -Body $Body `
    -ContentType $ContentType

  if ($Result.StatusCode -eq "201") {
    Write-Host "Output saved to $ContainerName\$BlobName."
  }
  else {
    throw "Error saving to $ContainerName\$BlobName."
  }
}

function Read-MostRecentResults {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][String]$ContainerName
  )

  $xml = Get-Blobs `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName

  $Blobs = $xml.enumerationResults.blobs.blob

  $AllBlobs = foreach ($Blob in $Blobs) {
    # Cast the blob's Creation-Time property from string to DateTime
    [DateTime]$CreationTime = $Blob.properties.'Creation-Time'

    [PSCustomObject]@{
      "Name"          = $Blob.Name
      "Creation-Time" = $CreationTime
    }
  }

  if ($AllBlobs.length -eq 0) {
    Write-Host "No blobs found in container: $ContainerName"
    break
  }

  if ($AllBlobs.length -eq 1) {
    Write-Host "No previous results found in: $ContainerName"
    break
  }

  $AllBlobs = $AllBlobs | Sort-Object -Property 'Creation-Time' -Descending

  $Results = Read-Blob `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName `
    -BlobName $AllBlobs[1].Name

  return $Results 
}

function Read-AggregateResults {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][String]$ContainerName,
    [Parameter(Mandatory = $true)][int]$DaysToAggregate
  )

  $Today = Get-Date

  $xml = Get-Blobs `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName

  $Blobs = $xml.enumerationResults.blobs.blob

  $DaysToAggregate = ($DaysToAggregate * -1)

  $AllBlobs = foreach ($Blob in $Blobs) {
    # Cast the blob's Creation-Time property from string to DateTime
    [DateTime]$CreationTime = $Blob.properties.'Creation-Time'

    if ($CreationTime -ge $Today.AddDays($DaysToAggregate)) {
      [PSCustomObject]@{
        "Name"          = $Blob.Name
        "Creation-Time" = $CreationTime
      }
    }
  }

  if ($AllBlobs.length -eq 0) {
    Write-Host "No blobs found in container: $ContainerName"
    return
  }

  $AllBlobs = $AllBlobs | Sort-Object -Property 'Creation-Time' -Descending

  $DetectedAppAggregate = @{}

  foreach ($Blob in $AllBlobs) {
    $DetectedAppResults = Read-Blob `
      -StorageContext $StorageContext `
      -StorageContainer $ContainerName `
      -BlobName $Blob.Name `

    foreach ($App in $DetectedAppResults) {
      if ($DetectedAppAggregate.ContainsKey($App.Id)) {
        $Devices = $DetectedAppAggregate[$App.Id].Devices + $App.Devices
        $DetectedAppAggregate[$App.Id].Devices = $Devices | Sort-Object -Unique
      }
      else {
        $DetectedAppAggregate[$App.Id] = $App
      }
    }
  }

  return $DetectedAppAggregate.Values
  
}

Export-ModuleMember -Function Save-Results, Read-MostRecentResults, Read-AggregateResults