function Get-Blobs {
  param(
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][string]$StorageContainer
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
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][string]$StorageContainer,
    [Parameter(Mandatory=$true)][string]$BlobName
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
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][string]$StorageContainer,
    [Parameter(Mandatory=$true)][string]$BlobName,
    [Parameter(Mandatory=$true)][string]$Body,
    [Parameter(Mandatory=$true)][string]$ContentType
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
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][string]$StorageContainer,
    [Parameter(Mandatory=$true)][string]$BlobName
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
    "x-ms-date"      = "$(Get-Date)"
  }
  
  $Response = Invoke-WebRequest `
    -Method "DELETE" `
    -Uri $SASTokenFull `
    -Headers $Headers

  return $Response
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
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName `
    -BlobName $BlobName `
    -Body $Body `
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
    [Parameter(Mandatory=$false)][int]$WithinLastDays
  )

  if (!$MostRecent -and !$WithinLastDays) {
    throw "Get-CSVFromContainer - You must specify one of the following parameters: -MostRecent, -WithinLastDays"
  }
  
  # Flip to a negative integer so .AddDays() subtracts from $Today
  $WithinLastDays = ($WithinLastDays * -1) 

  $Today = Get-Date

  $xml = Get-Blobs `
    -StorageContext $StorageContext `
    -StorageContainer $ContainerName

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
      -StorageContext $StorageContext `
      -StorageContainer $ContainerName `
      -BlobName $Blob.Name `
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
        -StorageContext $StorageContext `
        -StorageContainer $ContainerName `
        -BlobName $Blob.Name

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

function Remove-OldBlobs {
  param(
    [Parameter(Mandatory=$true)][Microsoft.Azure.Commands.Common.Authentication.Abstractions.IStorageContext]$StorageContext,
    [Parameter(Mandatory=$true)][String]$ContainerName,
    [Parameter(Mandatory=$true)][int]$OlderThanDays
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

Export-ModuleMember -Function Get-Blobs, Read-Blob, Write-Blob, Save-CSVToBlob, Get-CSVFromContainer