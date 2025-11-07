# Input bindings are passed in via param block.
param($Timer)

# Log start time.
Write-Host 'Execution started at:' (Get-Date).ToUniversalTime()

# Execute script
. "$PSScriptRoot/Get-NewlyInstalledApps-Mg1.0.ps1"

# Log end time.
Write-Host 'Execution ended at:' (Get-Date).ToUniversalTime()