# Keyvault-Acmebot v5 Deployment Fix

## Problem Summary

Deploying the v5 Bicep template (`azuredeploy.bicep`) to Azure failed with a `BadRequest` error on the `Microsoft.Web/sites/extensions/onedeploy` resource. Even after manual intervention, the function app remained in a `ServiceUnavailable` state.

## Root Causes Identified

### 1. `onedeploy` extension not supported on Flex Consumption

The v5 template switched from **Consumption** (`Y1`/`Dynamic`) to **Flex Consumption** (`FC1`/`FlexConsumption`). The `onedeploy` site extension (`Microsoft.Web/sites/extensions`) is not supported on Flex Consumption plans.

**Bicep resource that fails:**

```bicep
resource functionAppDeploy 'Microsoft.Web/sites/extensions@2025-03-01' = {
  parent: functionApp
  name: 'onedeploy'
  properties: {
    packageUri: 'https://stacmebotprod.blob.core.windows.net/keyvault-acmebot/v5/latest.zip'
    remoteBuild: false
  }
}
```

**Fix:** Remove the `functionAppDeploy` resource. For Flex Consumption, deploy the zip by uploading it to the deployment blob container and using `az functionapp deploy` or the REST API.

### 2. Deployment storage authentication mismatch

The Bicep template specifies `StorageAccountConnectionString` authentication:

```bicep
authentication: {
  type: 'StorageAccountConnectionString'
  storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
}
```

However, the deployed function app was configured with `SystemAssignedIdentity` authentication. The function app's managed identity lacked the **Storage Blob Data Contributor** role on the storage account, preventing it from reading the deployment package.

**Fix:** Grant `Storage Blob Data Contributor` to the function app's managed identity on the storage account, and update the Bicep template to use `SystemAssignedIdentity`.

### 3. Key-based storage authentication blocked

The `AzureWebJobsStorage` app setting used a connection string with account keys:

```
DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...
```

The storage account had key-based authentication disabled, resulting in a 403 `KeyBasedAuthenticationNotPermitted` error at runtime.

**Fix:** Replace `AzureWebJobsStorage` connection string with the identity-based setting `AzureWebJobsStorage__accountName`, and grant the required storage roles.

### 4. Missing `FUNCTIONS_EXTENSION_VERSION` app setting

The v5 template omitted the `FUNCTIONS_EXTENSION_VERSION` app setting (present as `~4` in v4).

**Fix:** Add `FUNCTIONS_EXTENSION_VERSION` = `~4` as an app setting.

> Note: `FUNCTIONS_WORKER_RUNTIME` is **not allowed** on Flex Consumption — the runtime is configured via `functionAppConfig.runtime` instead.

---

## Fixes Applied (via CLI)

### Prerequisites

Set the following variables to match your environment before running the commands:

```bash
# Required: Replace these values with your own
SUBSCRIPTION_ID="<your-subscription-id>"
RESOURCE_GROUP="<your-resource-group>"
FUNCTION_APP_NAME="<your-function-app-name>"
STORAGE_ACCOUNT_NAME="<your-storage-account-name>"
DEPLOYMENT_CONTAINER_NAME="<your-deployment-container-name>"

# Derived values (no changes needed)
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

STORAGE_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME"
```

### Step 1: Remove connection-string-based app settings

```bash
az functionapp config appsettings delete \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --setting-names AzureWebJobsStorage DEPLOYMENT_STORAGE_CONNECTION_STRING
```

### Step 2: Add identity-based storage and missing settings

```bash
az functionapp config appsettings set \
  --name $FUNCTION_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --settings \
    AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME \
    FUNCTIONS_EXTENSION_VERSION=~4
```

### Step 3: Grant managed identity roles on the storage account

```bash
# Deployment storage access
az role assignment create --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" --scope $STORAGE_SCOPE

# AzureWebJobsStorage identity-based access
az role assignment create --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Owner" --scope $STORAGE_SCOPE

az role assignment create --assignee $PRINCIPAL_ID \
  --role "Storage Queue Data Contributor" --scope $STORAGE_SCOPE

az role assignment create --assignee $PRINCIPAL_ID \
  --role "Storage Table Data Contributor" --scope $STORAGE_SCOPE
```

> **Note:** RBAC role assignments can take up to 5 minutes to propagate. Wait before proceeding.

### Step 4: Deploy the application package

```bash
# Upload zip to the deployment blob container
az storage blob upload \
  --account-name $STORAGE_ACCOUNT_NAME \
  --container-name $DEPLOYMENT_CONTAINER_NAME \
  --name latest.zip \
  --file latest.zip \
  --overwrite \
  --auth-mode login
```

### Step 5: Trigger function sync

```bash
az rest --method POST \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/syncfunctiontriggers?api-version=2023-12-01"
```

### Step 6: Restart the function app

```bash
az functionapp restart --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP
```

---

## Required Bicep Template Changes

The following changes should be made to `deploy/azuredeploy.bicep` to prevent these issues on fresh deployments:

### 1. Remove `functionAppDeploy` (`onedeploy` extension)

Delete the entire `functionAppDeploy` resource block (lines 190-198).

### 2. Switch deployment storage to managed identity auth

```bicep
# Before
authentication: {
  type: 'StorageAccountConnectionString'
  storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
}

# After
authentication: {
  type: 'SystemAssignedIdentity'
}
```

### 3. Replace `AzureWebJobsStorage` connection string with identity-based setting

```bicep
# Before
{
  name: 'AzureWebJobsStorage'
  value: 'DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...'
}

# After
{
  name: 'AzureWebJobsStorage__accountName'
  value: storageAccountName
}
```

### 4. Remove `DEPLOYMENT_STORAGE_CONNECTION_STRING` app setting

No longer needed with identity-based deployment storage auth.

### 5. Add `FUNCTIONS_EXTENSION_VERSION` app setting

```bicep
{
  name: 'FUNCTIONS_EXTENSION_VERSION'
  value: '~4'
}
```

### 6. Add storage role assignments for the managed identity

Add role assignments for `Storage Blob Data Owner`, `Storage Blob Data Contributor`, `Storage Queue Data Contributor`, and `Storage Table Data Contributor` scoped to the storage account.

### 7. Add a deployment script for package deployment

Replace the `onedeploy` extension with a `Microsoft.Resources/deploymentScripts` resource that uploads the zip to the deployment blob container.
