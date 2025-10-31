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


function Get-DetectedAppsManagedDevicesBatch {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [array]$DetectedApps,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$BatchSize = 20
  )
  
  $Context = Get-MgContext
  if (-not $Context) {
    throw "Not connected to Microsoft Graph. Please run Connect-MgGraph first."
  }
  
  $BatchUri = "v1.0/`$batch"
  $Headers = @{
    "Content-Type" = "application/json"
  }
  
  # Process apps in batches
  $results = @()
  for ($i = 0; $i -lt $DetectedApps.Count; $i += $BatchSize) {
    $batchApps = $DetectedApps[$i..[Math]::Min($i + $BatchSize - 1, $DetectedApps.Count - 1)]
    
    # Build batch request body
    $requests = @()
    $requestIndex = 0
    foreach ($app in $batchApps) {
      $requests += @{
        id     = "$requestIndex"  # Use index to guarantee uniqueness within batch
        method = "GET"
        url    = "/deviceManagement/detectedApps/$($app.Id)/managedDevices?`$select=deviceName"
      }
      $requestIndex++
    }
    
    $BatchBody = @{
      requests = $requests
    } | ConvertTo-Json -Depth 10
    
    try {
      # Execute batch request
      $batchResponse = Invoke-MgGraphRequestWithRetry -Uri $BatchUri -Method Post -Headers $Headers -Body $BatchBody
      
      # Process responses and match back to apps
      foreach ($response in $batchResponse.responses) {
        # Use the index to find the corresponding app
        $appIndex = [int]$response.id
        $matchedApp = $batchApps[$appIndex]
        
        if ($response.status -eq 200) {
          # Extract device names from successful response
          $deviceNames = @()
          if ($response.body.value) {
            $deviceNames = $response.body.value | ForEach-Object { $_.deviceName }
          }
          
          # Create result object matching original structure
          $results += [PSCustomObject]@{
            Id          = $matchedApp.Id
            DisplayName = $matchedApp.DisplayName
            Publisher   = $matchedApp.Publisher
            Version     = $matchedApp.Version
            Devices     = $deviceNames
          }
        }
        else {
          # Handle failed individual request
          Write-Warning "Failed to get devices for app '$($matchedApp.DisplayName)' (ID: $($matchedApp.Id)). Status: $($response.status)"
          
          # Still add the app but with empty devices array
          $results += [PSCustomObject]@{
            Id          = $matchedApp.Id
            DisplayName = $matchedApp.DisplayName
            Publisher   = $matchedApp.Publisher
            Version     = $matchedApp.Version
            Devices     = @()
          }
        }
      }
    }
    catch {
      Write-Error "Batch request failed: $_"
      throw
    }
    
    # Rate-limit mitigation between batches
    if ($i + $BatchSize -lt $DetectedApps.Count) {
      Start-Sleep -Milliseconds 100
    }
  }
  
  return $results
}

Export-ModuleMember -Function Save-Results, Read-MostRecentResults, Read-AggregateResults, Get-DetectedAppsManagedDevicesBatch