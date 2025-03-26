function Send-Email {
  param (
      [string]$From,
      [string]$To,
      [string]$Subject,
      [string]$Body
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
  Invoke-MgGraphRequest -Uri $uri -Headers $headers -Method Post -Body ($email | ConvertTo-Json -Depth 10)
}

Export-ModuleMember -Function Send-Email