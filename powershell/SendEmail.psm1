function Send-Email {
  param (
      [Parameter(Mandatory=$true)][string]$From,
      [Parameter(Mandatory=$true)][string]$To,
      [Parameter(Mandatory=$true)][string]$Subject,
      [Parameter(Mandatory=$true)][string]$Body
  )
  
  $email = @{
      message = @{
          subject = $Subject
          body = @{
              contentType = "Text"
              content     = $Body
          }
          toRecipients = @(
              @{ emailAddress = @{ address = $To } }
          )
      }
      saveToSentItems = $true
  }
  
  $headers = @{
      "Content-Type" = "application/json"
  }
  
  $uri = "https://graph.microsoft.com/v1.0/users/$From/sendMail"
  Invoke-MgGraphRequest `
    -Uri $uri `
    -Headers $headers `
    -Method Post `
    -Body ($email | ConvertTo-Json -Depth 10)
}

Export-ModuleMember -Function Send-Email