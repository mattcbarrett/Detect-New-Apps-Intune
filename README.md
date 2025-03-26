# Azure resource creation
New-AzResourceGroup -Name resource_group_name -Location westus2

New-AzStorageAccount -ResourceGroupName resource_group_name -Name storage_account_name -Location westus2 -SkuName Standard_LRS -AllowBlobPublicAccess $true

New-AzStorageContainer -Name storage_container_name -Permission off -AllowSharedKeyAccess $true -Context (New-AzStorageContext -StorageAccountName storage_account_name)

New-AzRoleAssignment -SignInName azure_user_name@domain.com -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$((Get-AzSubscription).Id)/resourceGroups/resource_group_name/providers/Microsoft.Storage/storageAccounts/storage_account_name"

# App setup

## Environment variables
Located in env.psd1

- MIN_AGE
  - Minimum detected apps csv file age in days
- EMAIL_FROM
  - Email address that notifications are sent from
- EMAIL_TO
  - Email address that notifications are sent to
- STORAGE_ACCOUNT
  - Name of the storage account you created above
- STORAGE_CONTAINER
  - Name of the storage container that you created above
- BLOB_NAME_PREFIX
  - Prefix for the csv filenames uploaded to blob storage. Filename is _detected_apps_$date.csv by default.

## Running locally
Once Azure resources have been created and environment variables set, execute Get-NewlyInstalledApps.ps1.

## Running in Azure Functions on recurring timer
TBD