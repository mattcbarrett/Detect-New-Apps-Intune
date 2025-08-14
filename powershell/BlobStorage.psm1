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

function Save-CSVToBlob {
  param(
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][String]$ContainerName,
    [Parameter(Mandatory=$true)][String]$BlobName,
    [Parameter(Mandatory=$true)]$Data
  )

  $Data = $Data | Sort-Object -Property DisplayName

  $Body = ($Data | ConvertTo-Csv -NoTypeInformation) -join "`n"

  $Result = Write-Blob `
    -storageContext $StorageContext `
    -storageContainer $ContainerName `
    -blobName $BlobName `
    -body $Body `
    -ContentType "text/csv;charset=utf-8"

  if ($Result.StatusCode -eq "201") {
    Write-Host "Output saved to $ContainerName\$BlobName."
  } else {
    throw "Error saving to $ContainerName\$BlobName."
  }
}

function Get-CSVFromContainer {
  param(
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][String]$ContainerName,
    [Parameter(Mandatory=$false)][Switch]$MostRecent,
    [Parameter(Mandatory=$false)][sbyte]$WithinLastDays
  )

  if (!$MostRecent -and !$WithinLastDays) {
    throw "Get-CSVFromContainer - You must specify one of the following parameters: -MostRecent, -WithinLastDays"
  }
  
  # Flip to a negative integer so .AddDays() subtracts from $Today
  $WithinLastDays = ($WithinLastDays * -1) 

  $Today = Get-Date

  $xml = Get-Blobs `
    -storageContext $StorageContext `
    -storageContainer $ContainerName

  $Blobs = $xml.enumerationResults.blobs.blob

  $AllBlobs = @()

  foreach ($Blob in $Blobs) {
    # Cast the blob's Creation-Time property from string to DateTime
    [DateTime]$CreationTime = $Blob.properties.'Creation-Time'

    if ($CreationTime -le $Today.AddDays(-1)) { # Get everything older than today
      $AllBlobs += [PSCustomObject]@{
          "Name" = $Blob.Name
          "Creation-Time" = $CreationTime
        }
    }
  }

  if ($AllBlobs.length -eq 0) {
    Write-Host "No blobs found in container: $ContainerName"
    return
  }

  $AllBlobs = $AllBlobs | Sort-Object -Property 'Creation-Time' -Descending

  if ($MostRecent) {
    Write-Host "Retrieving the most recent CSV from container: $ContainerName"

    $Blob = $AllBlobs[0]

    Write-Host "Selected file: $($Blob.Name)."

    $Result = Read-Blob `
      -storageContext $StorageContext `
      -storageContainer $ContainerName `
      -blobName $Blob.Name `
      | ConvertFrom-Csv

    if ($Result) {
      return $Result
    } else {
      throw "Retrieving file $($LatestBlob.Name) failed."
    }

  } else {
    Write-Host "Retrieving all CSV files created within the previous $($WithinLastDays * -1) days from container: $ContainerName"

    $PreviousBlobs = @()
    
    foreach ($Blob in $AllBlobs) {
      # Cast the blob's Creation-Time property from string to DateTime
      [DateTime]$CreationTime = $Blob.'Creation-Time'

      if ($CreationTime -ge $Today.AddDays($WithinLastDays)) {
        $PreviousBlobs += [PSCustomObject]@{
            "Name" = $Blob.Name
            "Creation-Time" = $CreationTime
          }
      }
    }

    if ($PreviousBlobs.length -eq 0) {
      Write-Host "No matching blobs found in container: $ContainerName"
      return
    }

    $CombinedCSV = @()

    foreach ($Blob in $PreviousBlobs) {
      $Result = Read-Blob `
        -storageContext $StorageContext `
        -storageContainer $ContainerName `
        -blobName $Blob.Name

      if ($Result) {
        Write-Host "Retrieved file $($Blob.name)."
      } else {
        throw "Retrieving file $($Blob.name) failed."
      }

      $CombinedCSV += $Result | ConvertFrom-Csv
    }

    return $CombinedCSV
  }
}

Export-ModuleMember -Function Get-Blobs, Read-Blob, Write-Blob, Save-CSVToBlob, Get-CSVFromContainer