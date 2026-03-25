# Using Azure Key Vault for SSL Certificate Management on IIS (VM)

A step-by-step guide to securing an IIS Web App on an Azure VM using SSL certificates managed by Azure Key Vault and issued by Acmebot.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Deploy Acmebot and Issue a Certificate](#step-1--deploy-acmebot-and-issue-a-certificate)
4. [Step 2 — Grant the VM Access to Key Vault](#step-2--grant-the-vm-access-to-key-vault)
5. [Step 3 — Install the Key Vault VM Extension](#step-3--install-the-key-vault-vm-extension)
6. [Step 4 — Bind the Certificate to IIS](#step-4--bind-the-certificate-to-iis)
7. [Step 5 — Automated Certificate Renewal (Zero-Touch)](#step-5--automated-certificate-renewal-zero-touch)
8. [Step 6 — Verify and Test](#step-6--verify-and-test)
9. [Step 7 — Monitoring and Troubleshooting](#step-7--monitoring-and-troubleshooting)
10. [Security Best Practices](#security-best-practices)

---

## 1. Architecture Overview

```
┌─────────────────────┐        ┌──────────────────────┐        ┌──────────────────────┐
│   ACME CA           │        │   Azure Key Vault    │        │   Azure VM (IIS)     │
│  (Let's Encrypt /   │◄──────►│                      │◄──────►│                      │
│   ZeroSSL / etc.)   │  ACME  │  Stores certificates │  Reads │  Windows Server      │
└─────────────────────┘  proto │  as Key Vault        │  certs │  + IIS               │
                         col   │  Certificate objects  │        │  + Key Vault VM Ext  │
         ▲                     └──────────────────────┘        └──────────────────────┘
         │                              ▲
         │                              │
┌─────────────────────┐                 │
│   Acmebot           │─────────────────┘
│  (Azure Functions)  │  Issues & renews certs,
│                     │  stores in Key Vault
└─────────────────────┘
```

**Flow:**

1. **Acmebot** (Azure Functions) automatically issues SSL certificates via the ACME protocol
2. Certificates are stored centrally in **Azure Key Vault**
3. The **Azure VM** pulls certificates from Key Vault using the **Key Vault VM Extension** (recommended)
4. **IIS** is configured to use the certificate for HTTPS bindings
5. On renewal, the extension uses **CNG certificate linking** (`linkOnRenewal: true`) to transparently update the certificate — **IIS continues working with no script or rebinding needed**

---

## 2. Prerequisites

| Requirement | Details |
|---|---|
| **Azure Subscription** | With permissions to create resources |
| **Acmebot Deployed** | See the main [README](../README.md) for deployment buttons |
| **Azure Key Vault** | Created by Acmebot deployment (or an existing one) |
| **Azure VM** | Windows Server 2016+ with IIS installed |
| **DNS Zone** | Managed in Azure DNS (or a supported DNS provider) |
| **Domain Name** | Pointed to your VM's public IP |
| **Managed Identity** | System-assigned or user-assigned on the VM |

---

## Step 1 — Deploy Acmebot and Issue a Certificate

### 1.1 Deploy Acmebot

If not already deployed, use the Deploy to Azure button from the [README](../README.md) or run the Bicep template:

```bash
az deployment group create \
  --resource-group myResourceGroup \
  --template-file deploy/azuredeploy.bicep \
  --parameters mailAddress=admin@example.com \
               dnsZoneResourceGroupName=myDnsRG \
               dnsZoneNames='["example.com"]'
```

### 1.2 Issue a Certificate

Use the Acmebot dashboard or the REST API to issue a certificate for your domain:

**Via REST API:**

```bash
# Get the Function App URL from the Azure Portal
FUNCTION_URL="https://<your-acmebot>.azurewebsites.net"

# Issue a certificate (requires authentication)
curl -X POST "$FUNCTION_URL/api/certificate" \
  -H "Content-Type: application/json" \
  -d '{
    "dnsZoneId": "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Network/dnsZones/example.com",
    "dnsNames": ["www.example.com"],
    "certificateName": "www-example-com"
  }'
```

### 1.3 Verify the Certificate in Key Vault

```bash
# List certificates in the Key Vault
az keyvault certificate list \
  --vault-name <your-keyvault-name> \
  --query "[].{Name:name, Expires:attributes.expires}" \
  --output table
```

You should see your certificate listed. Note the **certificate name** — you'll need it later.

---

## Step 2 — Grant the VM Access to Key Vault

The VM needs permission to read certificates from Key Vault. The recommended approach uses **Managed Identity** with **Azure RBAC** (no access policies needed).

### 2.1 Enable System-Assigned Managed Identity on the VM

```bash
az vm identity assign \
  --resource-group myResourceGroup \
  --name myVM
```

Note the `principalId` in the output — you'll need it for the role assignment.

### 2.2 Grant "Key Vault Secrets User" Role

The VM needs the **Key Vault Secrets User** role to read certificate secrets (which include the private key):

```bash
# Get the VM's managed identity principal ID
VM_PRINCIPAL_ID=$(az vm identity show \
  --resource-group myResourceGroup \
  --name myVM \
  --query principalId \
  --output tsv)

# Get the Key Vault resource ID
KV_RESOURCE_ID=$(az keyvault show \
  --name <your-keyvault-name> \
  --query id \
  --output tsv)

# Assign the role
az role assignment create \
  --assignee-object-id $VM_PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope $KV_RESOURCE_ID

# Wait for RBAC propagation (important — role assignments can take up to 30 seconds)
sleep 30
```

> **Why "Key Vault Secrets User"?**
> Azure Key Vault stores the certificate's private key as a secret. To download the full certificate (with private key, i.e. PFX), the identity needs access to **secrets**, not just certificates. The "Key Vault Secrets User" role grants `Microsoft.KeyVault/vaults/secrets/getSecret/action`.

### 2.3 Ensure Key Vault Uses RBAC (Not Access Policies)

If your Key Vault was created by Acmebot, verify it uses Azure RBAC:

```bash
az keyvault show \
  --name <your-keyvault-name> \
  --query "properties.enableRbacAuthorization"
```

If it returns `false`, you can either:
- **Switch to RBAC** (recommended):
  ```bash
  az keyvault update \
    --name <your-keyvault-name> \
    --enable-rbac-authorization true
  ```
- **Or use Access Policies** (legacy approach):
  ```bash
  az keyvault set-policy \
    --name <your-keyvault-name> \
    --object-id $VM_PRINCIPAL_ID \
    --secret-permissions get list \
    --certificate-permissions get list
  ```

---

## Step 3 — Install the Key Vault VM Extension

The **Azure Key Vault VM Extension** automatically pulls certificates from Key Vault, installs them in the Windows certificate store, and refreshes them on a polling interval. This is the **recommended approach** for production.

### 3.1 Install the Extension via Azure CLI

```bash
az vm extension set \
  --resource-group myResourceGroup \
  --vm-name myVM \
  --name KeyVaultForWindows \
  --publisher Microsoft.Azure.KeyVault \
  --version 3.0 \
  --settings '{
    "secretsManagementSettings": {
      "pollingIntervalInS": "3600",
      "linkOnRenewal": true,
      "requireInitialSync": true,
      "observedCertificates": [
        {
          "url": "https://<your-keyvault-name>.vault.azure.net/secrets/<certificate-name>",
          "certificateStoreName": "My",
          "certificateStoreLocation": "LocalMachine"
        }
      ]
    },
    "authenticationSettings": {
      "msiEndpoint": "http://169.254.169.254/metadata/identity/oauth2/token",
      "msiClientId": ""
    }
  }'
```

**Key parameters:**

| Parameter | Description |
|---|---|
| `pollingIntervalInS` | How often (in seconds) the extension checks for updated certificates. Default: `3600` (1 hour). |
| `linkOnRenewal` | When `true`, the extension updates the existing certificate in the store (preserving the thumbprint link) instead of adding a new one. |
| `requireInitialSync` | When `true`, the extension will fail provisioning if the initial certificate download fails. |
| `observedCertificates[].url` | The Key Vault **secret** URI (not the certificate URI). Format: `https://<vault>.vault.azure.net/secrets/<cert-name>`. Omit the version to always get the latest. |
| `certificateStoreName` | Windows cert store name — use `My` for "Personal" store. |
| `certificateStoreLocation` | `LocalMachine` or `CurrentUser`. IIS requires `LocalMachine`. |
| `msiClientId` | Leave empty for system-assigned identity. Set to the client ID for user-assigned identity. |

### 3.2 Install via Bicep (Infrastructure as Code)

If you manage your VM with Bicep, add the extension to your template:

```bicep
resource kvExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'KeyVaultForWindows'
  location: vm.location
  properties: {
    publisher: 'Microsoft.Azure.KeyVault'
    type: 'KeyVaultForWindows'
    typeHandlerVersion: '3.0'
    autoUpgradeMinorVersion: true
    settings: {
      secretsManagementSettings: {
        pollingIntervalInS: '3600'
        linkOnRenewal: true
        requireInitialSync: true
        observedCertificates: [
          {
            url: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/${certificateName}'
            certificateStoreName: 'My'
            certificateStoreLocation: 'LocalMachine'
          }
        ]
      }
      authenticationSettings: {
        msiEndpoint: 'http://169.254.169.254/metadata/identity/oauth2/token'
        msiClientId: ''
      }
    }
  }
}
```

### 3.3 Verify the Extension Is Working

Check the extension status via Azure CLI:

```bash
az vm extension show \
  --resource-group myResourceGroup \
  --vm-name myVM \
  --name KeyVaultForWindows \
  --query "{Status:provisioningState, Publisher:publisher, Version:typeHandlerVersion}" \
  --output table
```

Verify the certificate landed in the VM's certificate store (via remote command):

```bash
az vm run-command invoke \
  --resource-group myResourceGroup \
  --vm-name myVM \
  --command-id RunPowerShellScript \
  --scripts "Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { \$_.Subject -like '*example.com*' } | Format-Table Subject, Thumbprint, NotAfter -AutoSize"
```

---

## Step 4 — Bind the Certificate to IIS

Once the certificate is in the Windows certificate store (`Cert:\LocalMachine\My`), configure IIS to use it via PowerShell.

> **Prerequisite:** IIS must be installed with management tools. If not already installed:
> ```powershell
> Install-WindowsFeature -Name Web-Server -IncludeManagementTools
> ```

### 4.1 Bind via PowerShell

```powershell
Import-Module WebAdministration

# Find the certificate by subject name
$cert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*example.com*" } |
    Sort-Object NotBefore -Descending |
    Select-Object -First 1

if (-not $cert) {
    Write-Error "Certificate for example.com not found in the certificate store."
    exit 1
}

$siteName = "Default Web Site"   # Change to your IIS site name
$hostHeader = "www.example.com"  # Change to your domain
$port = 443

# Remove existing HTTPS binding (if any) for this host
$existing = Get-WebBinding -Name $siteName -Protocol https -HostHeader $hostHeader -ErrorAction SilentlyContinue
if ($existing) {
    Remove-WebBinding -Name $siteName -Protocol https -HostHeader $hostHeader
    Write-Host "Removed existing HTTPS binding for $hostHeader"
}

# Create new HTTPS binding with SNI
New-WebBinding -Name $siteName `
    -Protocol https `
    -Port $port `
    -HostHeader $hostHeader `
    -SslFlags 1  # 1 = SNI enabled

# Associate the certificate with the binding
$binding = Get-WebBinding -Name $siteName -Protocol https -HostHeader $hostHeader
$binding.AddSslCertificate($cert.Thumbprint, "My")

Write-Host "HTTPS binding created for $hostHeader using certificate: $($cert.Thumbprint)"
```

---

## Step 5 — Automated Certificate Renewal (Zero-Touch)

Acmebot automatically renews certificates in Key Vault. With the Key Vault VM Extension configured in Step 3 using `linkOnRenewal: true`, **certificate renewal is fully automatic with zero scripts**. Nothing else needs to be configured.

### How It Works

Normally, IIS bindings reference certificates by **thumbprint**. When a certificate is renewed, the new certificate has a different thumbprint, which would break the binding. The `linkOnRenewal` setting solves this using **Windows CNG (Cryptography Next Generation) certificate linking**:

1. **Initial deployment:** The extension downloads the certificate from Key Vault and installs it in the Windows certificate store. You bind IIS to this certificate's thumbprint (Step 5).
2. **On renewal:** When Acmebot renews the certificate in Key Vault, the extension detects the new version during its next polling cycle.
3. **CNG linking:** Instead of simply adding a second certificate, the extension creates a **CNG link** from the old certificate to the new one. The old certificate's private key is replaced with a pointer to the new certificate's private key material.
4. **IIS keeps working:** IIS still references the original thumbprint, but the CNG link transparently redirects to the new certificate's key. The TLS handshake serves the renewed certificate — **no binding update, no script, no restart.**

```
Renewal Timeline:

  Day 0 (initial)         Day 60 (renewal)        Day 120 (next renewal)
  +-----------------+     +-----------------+     +-----------------+
  | Cert v1         |     | Cert v2         |     | Cert v3         |
  | Thumbprint: AAA |     | Thumbprint: BBB |     | Thumbprint: CCC |
  +-----------------+     +-----------------+     +-----------------+
        |                       |                       |
        v                       v                       v
  IIS bound to AAA        CNG link: AAA->BBB      CNG link: AAA->CCC
  (serves Cert v1)        (serves Cert v2)        (serves Cert v3)
                          IIS still uses AAA      IIS still uses AAA
                          No change needed!       No change needed!
```

### Extension Configuration (Already Done in Step 3)

The extension settings from Step 3 already include everything needed:

```json
{
  "secretsManagementSettings": {
    "pollingIntervalInS": "3600",
    "linkOnRenewal": true,
    "requireInitialSync": true,
    "observedCertificates": [
      {
        "url": "https://<vault>.vault.azure.net/secrets/<cert-name>",
        "certificateStoreName": "My",
        "certificateStoreLocation": "LocalMachine"
      }
    ]
  }
}
```

The critical settings:

| Setting | Value | Purpose |
|---|---|---|
| `linkOnRenewal` | `true` | Enables CNG linking so IIS bindings survive renewal without updates |
| `pollingIntervalInS` | `"3600"` | Extension checks Key Vault every hour for new certificate versions |
| `observedCertificates[].url` | Omit version | Always fetches the **latest** version of the certificate |

> **Important:** The certificate URL in `observedCertificates` must **not** include a version suffix. Use `https://<vault>.vault.azure.net/secrets/<cert-name>` (not `.../secrets/<cert-name>/<version>`). This ensures the extension always picks up the latest version.

### What Happens End-to-End

1. **Acmebot** renews the certificate (typically 30 days before expiry) and stores the new version in Key Vault
2. **Key Vault VM Extension** detects the new version within one polling interval (default: 1 hour)
3. **CNG link** is created — old thumbprint now points to new certificate
4. **IIS** serves the new certificate on the next TLS handshake — no restart, no rebinding
5. **You do nothing** — the entire chain is automatic

### Verifying CNG Linking Is Working

After a renewal occurs, you can verify the link on the VM:

```powershell
# List certificates — you should see both old and new
Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*example.com*" } |
    Format-Table Subject, Thumbprint, NotBefore, NotAfter -AutoSize

# Check the Key Vault VM Extension log for linking events
Get-Content "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.KeyVault.KeyVaultForWindows\*\akvvm_service*.log" -Tail 20 |
    Select-String -Pattern "link|renew"
```

---

## Step 6 — Verify and Test

### 6.1 Verify Certificate in Store

```powershell
# List all certificates for your domain
Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "*example.com*" } |
    Format-Table Subject, Thumbprint, NotBefore, NotAfter -AutoSize
```

### 6.2 Verify IIS Binding

```powershell
# List all HTTPS bindings
Get-WebBinding -Protocol https | Format-Table bindingInformation, certificateHash -AutoSize

# Or use netsh
netsh http show sslcert
```

### 6.3 Test HTTPS Connectivity

From any machine:

```bash
# Test with curl
curl -v https://www.example.com

# Test with OpenSSL (check certificate details)
openssl s_client -connect www.example.com:443 -servername www.example.com </dev/null 2>/dev/null | openssl x509 -noout -text -dates
```

From PowerShell:

```powershell
# Quick check
$result = Invoke-WebRequest -Uri "https://www.example.com" -UseBasicParsing
Write-Host "Status: $($result.StatusCode)"

# Detailed certificate check
$request = [System.Net.HttpWebRequest]::Create("https://www.example.com")
$request.GetResponse() | Out-Null
$cert = $request.ServicePoint.Certificate
Write-Host "Subject: $($cert.Subject)"
Write-Host "Issuer: $($cert.Issuer)"
Write-Host "Expires: $($cert.GetExpirationDateString())"
```

### 6.4 Test Certificate Renewal

Force Acmebot to renew the certificate, then verify the VM picks it up:

```bash
# Trigger renewal via Acmebot API
curl -X POST "$FUNCTION_URL/api/certificate/<cert-name>/renew"

# Wait for Key Vault VM Extension polling interval (or trigger manual sync)
# Then check the certificate store on the VM
```

---

## Step 7 — Monitoring and Troubleshooting

### 7.1 Key Vault VM Extension Logs

The extension writes logs to:

```
C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.KeyVault.KeyVaultForWindows\<version>\
```

Check for errors:

```powershell
Get-Content "C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.KeyVault.KeyVaultForWindows\*\akvvm_service*.log" -Tail 50
```

### 7.2 Common Issues

| Problem | Cause | Solution |
|---|---|---|
| Extension reports 403 Forbidden | VM identity lacks Key Vault permissions | Verify role assignment (Step 2.2) and that RBAC is enabled |
| Certificate not in store | Extension not polling, or wrong secret URL | Check the `observedCertificates` URL format — must use `/secrets/` not `/certificates/` |
| IIS shows old certificate after renewal | `linkOnRenewal` not enabled or CNG link failed | Verify extension has `linkOnRenewal: true` (Step 3); check extension logs for errors |
| SSL handshake fails | Certificate doesn't match hostname | Verify the certificate's SAN entries include the IIS hostname |
| Extension fails to install | VM agent not running | Ensure the Azure VM Agent is running: `Get-Service WindowsAzureGuestAgent` |

### 7.3 Useful Diagnostic Commands

```powershell
# Check VM extension status
az vm extension show --resource-group myResourceGroup --vm-name myVM --name KeyVaultForWindows

# Check Key Vault audit logs for access attempts
az monitor activity-log list \
  --resource-id $(az keyvault show --name <vault> --query id -o tsv) \
  --offset 1h \
  --query "[?contains(operationName.value, 'SecretGet')]"

# Verify managed identity token acquisition on the VM
Invoke-RestMethod -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" -Headers @{Metadata="true"}
```

---

## Security Best Practices

1. **Use Managed Identity** — Never store Key Vault credentials on the VM. Use system-assigned or user-assigned managed identities.

2. **Principle of Least Privilege** — Assign only `Key Vault Secrets User` role, scoped to the specific Key Vault (not the subscription).

3. **Network Security** — Enable Key Vault firewall and allow access only from the VM's subnet:
   ```bash
   az keyvault network-rule add \
     --name <vault-name> \
     --subnet <vm-subnet-resource-id>
   ```

4. **Audit Logging** — Enable Key Vault diagnostic logging to a Log Analytics workspace:
   ```bash
   az monitor diagnostic-settings create \
     --resource $(az keyvault show --name <vault> --query id -o tsv) \
     --name "kv-audit" \
     --workspace <log-analytics-workspace-id> \
     --logs '[{"category":"AuditEvent","enabled":true}]'
   ```

5. **Certificate Rotation Monitoring** — Set alerts for certificates nearing expiration:
   ```bash
   # Acmebot handles renewal automatically, but add monitoring as a safety net
   az monitor metrics alert create \
     --name "cert-expiry-alert" \
     --resource-group myResourceGroup \
     --scopes $(az keyvault show --name <vault> --query id -o tsv) \
     --condition "avg Microsoft.KeyVault/vaults-Availability < 100" \
     --description "Key Vault availability alert"
   ```

6. **Use Private Endpoints** — For production, use Azure Private Link for Key Vault access:
   ```bash
   az network private-endpoint create \
     --name kv-private-endpoint \
     --resource-group myResourceGroup \
     --vnet-name myVNet \
     --subnet PrivateEndpointSubnet \
     --private-connection-resource-id $(az keyvault show --name <vault> --query id -o tsv) \
     --group-id vault \
     --connection-name kv-connection
   ```

## Summary

| Step | Action | Automation Level |
|---|---|---|
| **1** | Deploy Acmebot & issue certificate | One-time setup |
| **2** | Grant VM managed identity access | One-time setup |
| **3** | Install Key Vault VM Extension | One-time setup (auto-renews) |
| **4** | Bind certificate to IIS | One-time setup (renewal handled by CNG linking) |
| **5** | Automated renewal via `linkOnRenewal` | **Zero-touch** (no scripts) |
| **6** | Test and verify | On-demand |
| **7** | Monitor and troubleshoot | Ongoing |

With this setup, Acmebot handles certificate issuance and renewal in Key Vault, while the Key Vault VM Extension with `linkOnRenewal: true` ensures your IIS server always has the latest certificate — achieving **fully automated, zero-touch SSL management** for your VM-hosted web application. No renewal scripts, scheduled tasks, or manual intervention required.
