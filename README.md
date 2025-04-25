# Create resources in Azure
## Manual
New-AzResourceGroup -Name resource_group_name -Location westus2

New-AzStorageAccount -ResourceGroupName resource_group_name -Name storage_account_name -Location westus2 -SkuName Standard_LRS -AllowBlobPublicAccess $true

New-AzStorageContainer -Name storage_container_name -Permission off -AllowSharedKeyAccess $true -Context (New-AzStorageContext -StorageAccountName storage_account_name)

New-AzRoleAssignment -SignInName azure_user_name@domain.com -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$((Get-AzSubscription).Id)/resourceGroups/resource_group_name/providers/Microsoft.Storage/storageAccounts/storage_account_name"

## Bicep template

Retrieve your user's ObjectID:
```
az ad signed-in-user show --query id --output tsv
```

Retrieve a different user's ObjectID:
```
az ad user show --id user_principal_name --query id --output tsv
```

Copy the value and fill it in as a parameter when deploying the bicep template:
```
az deployment sub create --location westus2 --template-file ./bicep/main.bicep --parameter userPrincipalId='user_principal_name_guid_here'
```

Copy the values for properties.storageAccountName and properties.storageContainerName from the output and fill in the STORAGE_ACCOUNT and STORAGE_CONTAINER variables in the env.psd1.template file, then rename it to env.psd1.

# App setup

## Environment variables
Located in env.psd1 (rename env.psd1.template if you haven't already.)

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

## Running locally
Once the appropriate resources have been created in Azure and you've entered the environment variables, execute Get-NewlyInstalledApps.ps1.

## Running in Azure Functions on recurring timer
TBD