function Get-Blobs {
  param(
    $storageContext,
    [string]$storageContainer
  )

  $sasStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $sasExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $sasTokenFull = (New-AzStorageContainerSASToken -Context $storageContext -Container $storageContainer -Permission "l" -StartTime $sasStart -ExpiryTime $sasExpiry -FullUri) + "&restype=container&comp=list"
  
  $headers = @{ 
    "x-ms-date" = "$(Get-Date)"
  }
  
  $response = Invoke-RestMethod -Method "GET" -Uri $sasTokenFull -Headers $headers
  
  [xml]$response = ($response).Substring(1)

  return $response

}

function Read-Blob {
  param(
    $storageContext,
    [string]$storageContainer,
    [string]$blobName
  )
  
  $sasStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $sasExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $sasTokenFull = New-AzStorageBlobSASToken -Context $storageContext -Container $storageContainer -Blob $blobName -Permission "r" -StartTime $sasStart -ExpiryTime $sasExpiry -FullUri
  
  $headers = @{
    "x-ms-blob-type" = "BlockBlob"
    "x-ms-date"      = "$(Get-Date)"
  }
  
  $response = Invoke-RestMethod -Method "GET" -Uri $sasTokenFull -Headers $headers
  
  return $response

}

function Write-Blob {
  param(
    $storageContext,
    [string]$storageContainer,
    [string]$blobName,
    [string]$body,
    [string]$contentType
  )
  
  $sasStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $sasExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $sasTokenFull = New-AzStorageBlobSASToken -Context $storageContext -Container $storageContainer -Blob $blobName -Permission "w" -StartTime $sasStart -ExpiryTime $sasExpiry -FullUri
  
  $headers = @{
    "x-ms-blob-type" = "BlockBlob"
    "x-ms-date"      = "$(Get-Date)"
  }
  
  $response = Invoke-WebRequest -Method "PUT" -Uri $sasTokenFull -Body $body -Headers $headers -ContentType $contentType

  return $response
}

Export-ModuleMember -Function Get-Blobs, Read-Blob, Write-Blob