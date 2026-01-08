function Save-Results {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][String]$ContainerName,
    [Parameter(Mandatory = $true)][String]$BlobName,
    [Parameter(Mandatory = $true)]$Data
  )

  $Body = $Data | ConvertTo-Json -Depth 10
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

function Read-AggregateAppResults {
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

function Read-AggregateDeviceResults {
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

  $DeviceAggregate = @{}

  foreach ($Blob in $AllBlobs) {
    $DevicesWithApps = Read-Blob `
      -StorageContext $StorageContext `
      -StorageContainer $ContainerName `
      -BlobName $Blob.Name `

    foreach ($Device in $DevicesWithApps) {
      if ($DeviceAggregate.ContainsKey($Device.Id)) {
        $Apps = @($DeviceAggregate[$Device.Id].Apps) + @($Device.Apps | Select-Object -ExpandProperty displayName)
        $Apps = $Apps -join ', '
        $DeviceAggregate[$Device.Id].Apps = $Apps | Sort-Object -Unique
      }
      else {
        $Device.Apps = $Device.Apps | Select-Object -ExpandProperty displayName
        $DeviceAggregate[$Device.Id] = $Device
      }
    }
  }

  return $DeviceAggregate.Values
  
}

function Invoke-MgGraphRequestWithRetry {
  param(
    [string]$Uri,
    [string]$Method = "GET",
    [object]$Body = $null,
    [int]$MaxRetries = 5
  )
    
  $retryCount = 0
    
  while ($retryCount -le $MaxRetries) {
    try {
      $params = @{
        Uri    = $Uri
        Method = $Method
      }
      if ($Body) { $params.Body = $Body }
            
      return Invoke-MgGraphRequest @params
    }
    catch {
      if ($_.Exception.Response.StatusCode -eq 429) {
        if ($retryCount -eq $MaxRetries) {
          throw "Max retries reached. $_"
        }
                
        # Exponential backoff: 2, 4, 8, 16, 32 seconds
        $waitTime = [math]::Pow(2, $retryCount + 1)
        Write-Warning "Rate limited. Waiting $waitTime seconds..."
        Start-Sleep -Seconds $waitTime
        $retryCount++
      }
      else {
        throw
      }
    }
  }
}

function Get-DetectedAppManagedDevices {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AppId
  )

  $Context = Get-MgContext
  if (-not $Context) {
    throw "Not connected to Microsoft Graph. Please run Connect-MgGraph first."
  }

  $Uri = "v1.0/deviceManagement/detectedApps/$($AppId)/managedDevices?`$select=deviceName"
  $Method = "GET"
  $MaxRetries = 5

  try {
    $results = Invoke-MgGraphRequestWithRetry -Uri $Uri -Method $Method -MaxRetries $MaxRetries

    return $results.value
  }
  catch {
    return $null
  }
}

function Get-ManagedDeviceDetectedApps {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceId
  )

  $Context = Get-MgContext
  if (-not $Context) {
    throw "Not connected to Microsoft Graph. Please run Connect-MgGraph first."
  }

  $Uri = "beta/deviceManagement/managedDevices/$($DeviceId)/detectedApps?`$select=id,displayName,version"
  $Method = "GET"
  $MaxRetries = 5

  try {
    $results = Invoke-MgGraphRequestWithRetry -Uri $Uri -Method $Method -MaxRetries $MaxRetries

    return $results.value
  }
  catch {
    return $null
  }
}

Export-ModuleMember -Function Save-Results, Read-MostRecentResults, Read-AggregateAppResults, Read-AggregateDeviceResults, Invoke-MgGraphRequestWithRetry, Get-DetectedAppManagedDevices, Get-ManagedDeviceDetectedApps