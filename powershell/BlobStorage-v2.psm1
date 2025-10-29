function Get-Blobs {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][string]$StorageContainer
  )

  $SASStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $SASExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $SASTokenFull = (New-AzStorageContainerSASToken `
      -Context $StorageContext `
      -Container $StorageContainer `
      -Permission "l" `
      -StartTime $SASStart `
      -ExpiryTime $SASExpiry `
      -FullUri) `
    + "&restype=container&comp=list"
  
  $Headers = @{ 
    "x-ms-date" = "$(Get-Date)"
  }
  
  $Response = Invoke-RestMethod `
    -Method "GET" `
    -Uri $SASTokenFull `
    -Headers $Headers
  
  [xml]$Response = ($Response).Substring(1)

  return $Response

}

function Read-Blob {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][string]$StorageContainer,
    [Parameter(Mandatory = $true)][string]$BlobName
  )
  
  $SASStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $SASExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $SASTokenFull = New-AzStorageBlobSASToken `
    -Context $StorageContext `
    -Container $StorageContainer `
    -Blob $BlobName `
    -Permission "r" `
    -StartTime $SASStart `
    -ExpiryTime $SASExpiry `
    -FullUri
  
  $Headers = @{
    "x-ms-blob-type" = "BlockBlob"
    "x-ms-date"      = "$(Get-Date)"
  }
  
  $Response = Invoke-RestMethod `
    -Method "GET" `
    -Uri $SASTokenFull `
    -Headers $Headers
  
  return $Response

}

function Write-Blob {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][string]$StorageContainer,
    [Parameter(Mandatory = $true)][string]$BlobName,
    [Parameter(Mandatory = $true)][string]$Body,
    [Parameter(Mandatory = $true)][string]$ContentType
  )
  
  $SASStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $SASExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $SASTokenFull = New-AzStorageBlobSASToken `
    -Context $StorageContext `
    -Container $StorageContainer `
    -Blob $BlobName `
    -Permission "w" `
    -StartTime $SASStart `
    -ExpiryTime $SASExpiry `
    -FullUri
  
  $Headers = @{
    "x-ms-blob-type" = "BlockBlob"
    "x-ms-date"      = "$(Get-Date)"
  }
  
  $Response = Invoke-WebRequest `
    -Method "PUT" `
    -Uri $SASTokenFull `
    -Body $Body `
    -Headers $Headers `
    -ContentType $ContentType

  return $Response
}

function Remove-Blob {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][string]$StorageContainer,
    [Parameter(Mandatory = $true)][string]$BlobName
  )
  
  $SASStart = (Get-Date).AddSeconds(-15).ToUniversalTime() #allow for clock drift
  $SASExpiry = (Get-Date).AddSeconds(15).ToUniversalTime()

  $SASTokenFull = New-AzStorageBlobSASToken `
    -Context $StorageContext `
    -Container $StorageContainer `
    -Blob $BlobName `
    -Permission "d" `
    -StartTime $SASStart `
    -ExpiryTime $SASExpiry `
    -FullUri
  
  $Headers = @{
    "x-ms-date" = "$(Get-Date)"
  }
  
  $Response = Invoke-WebRequest `
    -Method "DELETE" `
    -Uri $SASTokenFull `
    -Headers $Headers

  return $Response
}

function Remove-OldBlobs {
  param(
    [Parameter(Mandatory = $true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory = $true)][String]$ContainerName,
    [Parameter(Mandatory = $true)][int]$OlderThanDays
  )

  # Flip to a negative integer so .AddDays() subtracts from $Today
  $OlderThanDays = ($OlderThanDays * -1) 

  $Today = Get-Date

  $xml = Get-Blobs `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName

  $Blobs = $xml.enumerationResults.blobs.blob

  foreach ($Blob in $Blobs) {
    # Cast the blob's Creation-Time property from string to DateTime
    [DateTime]$CreationTime = $Blob.properties.'Creation-Time'

    if ($CreationTime -le $Today.AddDays($OlderThanDays)) {
      $Result = Remove-Blob `
        -StorageContext $StorageContext `
        -StorageContainer $ContainerName `
        -BlobName $Blob.name

      if ($Result) {
        Write-Host "Pruned blob $($Blob.name) with timestamp $($CreationTime)."

      }
    }
  }
}

Export-ModuleMember -Function Get-Blobs, Read-Blob, Write-Blob, Remove-OldBlobs