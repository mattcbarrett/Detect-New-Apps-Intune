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

function Get-DetectedAppsManagedDevicesBatch {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [array]$DetectedApps,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$BatchSize = 20,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 5,
    
    [Parameter(Mandatory = $false)]
    [int]$InitialDelaySeconds = 5
  )
  
  # Verify we're connected to Microsoft Graph
  $context = Get-MgContext
  if (-not $context) {
    throw "Not connected to Microsoft Graph. Please run Connect-MgGraph first."
  }
  
  # Global rate limit tracking
  $script:consecutiveRateLimits = 0
  $script:lastRateLimitTime = $null
  
  # Process apps in batches
  $results = @()
  for ($i = 0; $i -lt $DetectedApps.Count; $i += $BatchSize) {
    $batchApps = $DetectedApps[$i..[Math]::Min($i + $BatchSize - 1, $DetectedApps.Count - 1)]
    
    Write-Host "Processing batch $([Math]::Floor($i / $BatchSize) + 1) of $([Math]::Ceiling($DetectedApps.Count / $BatchSize)) (Apps $($i + 1)-$($i + $batchApps.Count))" -ForegroundColor Cyan
    
    # Apply proactive delay at the START of batch if we've had recent rate limits
    if ($script:consecutiveRateLimits -gt 0) {
      $proactiveDelay = $InitialDelaySeconds * [Math]::Pow(2, [Math]::Min($script:consecutiveRateLimits - 1, 5))
      Write-Host "  Proactive delay at batch start due to recent rate limits ($script:consecutiveRateLimits consecutive): $([Math]::Round($proactiveDelay, 2)) seconds" -ForegroundColor Yellow
      Start-Sleep -Seconds $proactiveDelay
    }
    
    # Build batch request body
    $requests = @()
    $batchIds = @{}
    
    foreach ($app in $batchApps) {
      # Check for duplicate IDs within this batch
      if ($batchIds.ContainsKey($app.Id)) {
        Write-Warning "Duplicate app ID detected in batch: $($app.Id) - Skipping duplicate entry"
        continue
      }
      
      $batchIds[$app.Id] = $true
      
      $requests += @{
        id     = $app.Id
        method = "GET"
        url    = "/deviceManagement/detectedApps/$($app.Id)/managedDevices?`$select=deviceName"
      }
    }
    
    # Skip batch if no valid requests
    if ($requests.Count -eq 0) {
      Write-Warning "No valid requests in batch starting at index $i"
      continue
    }
    
    $batchBody = @{
      requests = $requests
    }
    
    # Retry loop with exponential backoff
    $retryCount = 0
    $success = $false
    $hadRateLimitInBatch = $false
    
    while (-not $success -and $retryCount -le $MaxRetries) {
      try {
        # Execute batch request using Invoke-MgGraphRequest
        $batchResponse = Invoke-MgGraphRequest -Method POST -Uri "v1.0/`$batch" -Body $batchBody
        $success = $true
        
        # Process responses and match back to apps
        foreach ($response in $batchResponse.responses) {
          # Find the corresponding app using the id
          $matchedApp = $batchApps | Where-Object { $_.Id -eq $response.id }
          
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
        # Check if it's a 429 error
        $is429 = $false
        if ($_.Exception.Response.StatusCode -eq 429 -or 
          $_.Exception.Message -like "*429*" -or
          $_.Exception.Message -like "*throttled*" -or
          $_.Exception.Message -like "*rate limit*") {
          $is429 = $true
        }
        
        if ($is429 -and $retryCount -lt $MaxRetries) {
          $retryCount++
          $script:consecutiveRateLimits++
          $hadRateLimitInBatch = $true
          $script:lastRateLimitTime = Get-Date
          
          # Calculate exponential backoff delay - more aggressive
          $delaySeconds = $InitialDelaySeconds * [Math]::Pow(2, $retryCount - 1)
          
          # Add jitter to prevent thundering herd
          $jitter = Get-Random -Minimum 0 -Maximum ($delaySeconds * 0.2)
          $delaySeconds = $delaySeconds + $jitter
          
          # Check for Retry-After header
          $retryAfter = $null
          try {
            if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers['Retry-After']) {
              $retryAfter = $_.Exception.Response.Headers['Retry-After']
              if ($retryAfter -as [int]) {
                $delaySeconds = [Math]::Max($delaySeconds, [int]$retryAfter + 1)
              }
            }
          }
          catch {
            # Ignore header parsing errors
          }
          
          Write-Host "  Rate limited (429)! Retry $retryCount of $MaxRetries. Waiting $([Math]::Round($delaySeconds, 2)) seconds... (Consecutive limits: $script:consecutiveRateLimits)" -ForegroundColor Red
          Start-Sleep -Seconds $delaySeconds
        }
        elseif ($is429) {
          Write-Error "Max retries ($MaxRetries) exceeded due to rate limiting. Batch starting at index $i failed."
          throw
        }
        else {
          Write-Error "Batch request failed: $_"
          throw
        }
      }
    }
    
    # Only reset counter if we had a clean batch with no rate limits
    if ($success -and -not $hadRateLimitInBatch) {
      # Decay the counter gradually instead of resetting to zero
      if ($script:consecutiveRateLimits -gt 0) {
        $script:consecutiveRateLimits = [Math]::Max(0, $script:consecutiveRateLimits - 1)
        if ($script:consecutiveRateLimits -eq 0) {
          Write-Host "  Rate limits cleared - resuming normal operation" -ForegroundColor Green
        }
        else {
          Write-Host "  Rate limit counter decreased to $script:consecutiveRateLimits" -ForegroundColor Green
        }
      }
    }
    
    # Small delay between batches (only when not using proactive delay on next batch)
    if ($i + $BatchSize -lt $DetectedApps.Count -and $script:consecutiveRateLimits -eq 0) {
      Write-Host "  Waiting 0.5 seconds before next batch" -ForegroundColor Gray
      Start-Sleep -Milliseconds 500
    }
  }
  
  Write-Host "`nCompleted processing $($DetectedApps.Count) apps. Retrieved $($results.Count) results." -ForegroundColor Green
  
  return $results
}

Export-ModuleMember -Function Save-Results, Read-MostRecentResults, Read-AggregateResults, Get-DetectedAppsManagedDevicesBatch