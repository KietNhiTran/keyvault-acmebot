<#
.SYNOPSIS
    End-to-end verification script for the Key Vault → VM Extension → IIS SSL binding path.

.DESCRIPTION
    Provisions all Azure resources needed to verify the guide documented in
    docs/KEYVAULT_IIS_SSL_GUIDE.md WITHOUT deploying Acmebot.
    Uses a self-signed certificate created directly in Key Vault.

    Resources created:
      - Resource Group
      - Key Vault (RBAC-enabled) + self-signed certificate
      - VNet / Subnet / NSG / Public IP
      - Windows Server 2022 VM with IIS enabled (via Custom Script Extension)
      - System-assigned Managed Identity on the VM
      - RBAC role assignment (Key Vault Secrets User)
      - Key Vault VM Extension (pulls cert into LocalMachine\My)
      - IIS HTTPS binding via a remote PowerShell script

    After completion the script runs validation checks and prints a summary.

.PARAMETER ResourceGroupName
    Name of the resource group to create. Default: rg-kv-iis-verify

.PARAMETER Location
    Azure region. Default: australiaeast

.PARAMETER VmName
    Name of the VM. Default: vm-iis-test

.PARAMETER AdminUsername
    VM admin username. Default: azureadmin

.PARAMETER AdminPassword
    VM admin password (SecureString). If not supplied, you will be prompted.

.PARAMETER CertificateName
    Name of the self-signed certificate in Key Vault. Default: test-ssl-cert

.PARAMETER DnsLabel
    DNS label for the public IP (<label>.<region>.cloudapp.azure.com).
    Default: kviis<random 6 hex chars>

.PARAMETER SkipCleanup
    If set, resources are NOT deleted after verification.

.EXAMPLE
    .\Verify-KeyVaultIISBinding.ps1 -AdminPassword (ConvertTo-SecureString "P@ssw0rd1234!" -AsPlainText -Force) -SkipCleanup
#>

[CmdletBinding()]
param(
    [string]$Prefix            = "kviis",
    [string]$ResourceGroupName = "",
    [string]$Location          = "australiaeast",
    [string]$VmName            = "",
    [string]$AdminUsername     = "azureadmin",
    [SecureString]$AdminPassword,
    [string]$CertificateName   = "test-ssl-cert",
    [string]$DnsLabel          = "",
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
# Use "Continue" so az CLI warnings on stderr don't become terminating errors.
# All real error checking is done via Assert-AzCommand ($LASTEXITCODE).
$ErrorActionPreference = "Continue"

# ─────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n== $Msg ==" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Fail  { param([string]$Msg) Write-Host "   [FAIL] $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "   $Msg" -ForegroundColor Gray }

function Assert-AzCommand {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "$Step failed (exit code $LASTEXITCODE)"
        if ($ResourceGroupName -and (az group exists --name $ResourceGroupName --output tsv) -eq 'true') {
            Write-Info "Cleaning up resource group '$ResourceGroupName'..."
            az group delete --name $ResourceGroupName --yes --no-wait --output none 2>$null
            Write-Info "Resource group deletion initiated."
        }
        throw "Aborting: $Step failed."
    }
}

function Invoke-RemoteScript {
    # Runs a PowerShell script on the VM via az vm run-command invoke.
    # Uses -EncodedCommand to avoid PowerShell stripping $ variables
    # when passing script text to az CLI as arguments.
    param([string]$Script, [string]$RG, [string]$VM)
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Script)
    $encoded = [Convert]::ToBase64String($bytes)
    $wrapper = "powershell -EncodedCommand $encoded"
    $json = az vm run-command invoke `
        --resource-group $RG `
        --name $VM `
        --command-id RunPowerShellScript `
        --scripts $wrapper `
        --output json 2>$null
    return $json
}

# ─────────────────────────────────────────────────────────
# Prerequisites check
# ─────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"

$azVersion = az version 2>$null | ConvertFrom-Json
if (-not $azVersion) {
    throw "Azure CLI (az) is not installed or not in PATH."
}
Write-Ok "Azure CLI $($azVersion.'azure-cli') detected"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}
Write-Ok "Logged in as $($account.user.name) (subscription: $($account.name))"

# ─────────────────────────────────────────────────────────
# Prompt for password if not supplied
# ─────────────────────────────────────────────────────────
if (-not $AdminPassword) {
    $AdminPassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
}
$plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
)

# ─────────────────────────────────────────────────────────
# Derived names — all use $Prefix + random 4-char suffix
# ─────────────────────────────────────────────────────────
$suffix = -join ((1..4) | ForEach-Object { "{0:x}" -f (Get-Random -Maximum 16) })
if (-not $ResourceGroupName) { $ResourceGroupName = "rg-$Prefix-$suffix" }
if (-not $VmName)            { $VmName            = "vm-$Prefix-$suffix" }
if (-not $DnsLabel)          { $DnsLabel          = "$Prefix$suffix" }
$keyVaultName = "kv-$Prefix-$suffix"
$nsgName      = "$VmName-nsg"
$vnetName     = "$VmName-vnet"
$subnetName   = "default"
$pipName      = "$VmName-pip"
$nicName      = "$VmName-nic"
$fqdn         = "$DnsLabel.$Location.cloudapp.azure.com"

Write-Info "Resource Group : $ResourceGroupName"
Write-Info "Location       : $Location"
Write-Info "Key Vault      : $keyVaultName"
Write-Info "VM             : $VmName"
Write-Info "FQDN           : $fqdn"
Write-Info "Certificate    : $CertificateName"

# ─────────────────────────────────────────────────────────
# 1. Resource Group
# ─────────────────────────────────────────────────────────
Write-Step "1/10  Creating Resource Group"
az group create --name $ResourceGroupName --location $Location --output none
Assert-AzCommand "Create resource group"
Write-Ok "Resource group '$ResourceGroupName' created"

# ─────────────────────────────────────────────────────────
# 2. Key Vault (RBAC-enabled)
# ─────────────────────────────────────────────────────────
Write-Step "2/10  Creating Key Vault (RBAC mode)"
az keyvault create `
    --name $keyVaultName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --enable-rbac-authorization true `
    --output none
Assert-AzCommand "Create Key Vault"
Write-Ok "Key Vault '$keyVaultName' created with RBAC"

# Grant current user Key Vault Administrator so we can create the cert
$currentUserId = az ad signed-in-user show --query id --output tsv
$kvResourceId  = az keyvault show --name $keyVaultName --query id --output tsv

az role assignment create `
    --assignee-object-id $currentUserId `
    --assignee-principal-type User `
    --role "Key Vault Administrator" `
    --scope $kvResourceId `
    --output none
Assert-AzCommand "Grant Key Vault Administrator"
Write-Ok "Current user granted Key Vault Administrator"

# Wait for RBAC propagation
Write-Info "Waiting 30s for RBAC propagation..."
Start-Sleep -Seconds 30

# ─────────────────────────────────────────────────────────
# 3. Self-signed certificate in Key Vault
# ─────────────────────────────────────────────────────────
Write-Step "3/10  Creating self-signed certificate in Key Vault"

$certPolicy = @{
    issuerParameters = @{ name = "Self" }
    keyProperties    = @{ exportable = $true; keyType = "RSA"; keySize = 2048; reuseKey = $false }
    secretProperties = @{ contentType = "application/x-pkcs12" }
    x509CertificateProperties = @{
        subject          = "CN=$fqdn"
        subjectAlternativeNames = @{ dnsNames = @($fqdn) }
        validityInMonths = 12
    }
} | ConvertTo-Json -Depth 5

$policyFile = [System.IO.Path]::GetTempFileName()
$certPolicy | Set-Content -Path $policyFile -Encoding UTF8

az keyvault certificate create `
    --vault-name $keyVaultName `
    --name $CertificateName `
    --policy "@$policyFile" `
    --output none
Assert-AzCommand "Create certificate"
Remove-Item -Path $policyFile -Force

# Wait for cert to be ready
Write-Info "Waiting for certificate to be provisioned..."
$maxWait = 120; $elapsed = 0
do {
    Start-Sleep -Seconds 5; $elapsed += 5
    $certStatus = az keyvault certificate show `
        --vault-name $keyVaultName `
        --name $CertificateName `
        --query "attributes.enabled" `
        --output tsv 2>$null
} while ($certStatus -ne "true" -and $elapsed -lt $maxWait)

if ($certStatus -ne "true") {
    throw "Certificate was not provisioned within $maxWait seconds."
}

$certThumbprint = az keyvault certificate show `
    --vault-name $keyVaultName `
    --name $CertificateName `
    --query "x509ThumbprintHex" `
    --output tsv

Write-Ok "Certificate '$CertificateName' created (thumbprint: $certThumbprint)"

# ─────────────────────────────────────────────────────────
# 4. Networking (NSG, VNet, Public IP, NIC)
# ─────────────────────────────────────────────────────────
Write-Step "4/10  Creating networking resources"

# NSG — allow RDP and HTTPS inbound
az network nsg create --resource-group $ResourceGroupName --name $nsgName --output none
Assert-AzCommand "Create NSG"

az network nsg rule create `
    --resource-group $ResourceGroupName --nsg-name $nsgName `
    --name AllowRDP --priority 1000 --direction Inbound --access Allow `
    --protocol Tcp --destination-port-ranges 3389 --output none
Assert-AzCommand "Create NSG rule AllowRDP"

az network nsg rule create `
    --resource-group $ResourceGroupName --nsg-name $nsgName `
    --name AllowHTTPS --priority 1010 --direction Inbound --access Allow `
    --protocol Tcp --destination-port-ranges 443 --output none
Assert-AzCommand "Create NSG rule AllowHTTPS"

# VNet + Subnet
az network vnet create `
    --resource-group $ResourceGroupName --name $vnetName `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $subnetName --subnet-prefixes 10.0.0.0/24 `
    --output none
Assert-AzCommand "Create VNet"

# Public IP
az network public-ip create `
    --resource-group $ResourceGroupName --name $pipName `
    --allocation-method Static --sku Standard `
    --dns-name $DnsLabel `
    --output none
Assert-AzCommand "Create Public IP"

# NIC
az network nic create `
    --resource-group $ResourceGroupName --name $nicName `
    --vnet-name $vnetName --subnet $subnetName `
    --public-ip-address $pipName `
    --network-security-group $nsgName `
    --output none
Assert-AzCommand "Create NIC"

$publicIp = az network public-ip show `
    --resource-group $ResourceGroupName --name $pipName `
    --query ipAddress --output tsv

Write-Ok "Networking ready (Public IP: $publicIp, FQDN: $fqdn)"

# ─────────────────────────────────────────────────────────
# 5. Windows VM with IIS
# ─────────────────────────────────────────────────────────
Write-Step "5/10  Creating Windows Server 2022 VM with IIS"

# Try multiple VM sizes in case one is unavailable
$vmSizes = @("Standard_B2s", "Standard_D2s_v3", "Standard_D2s_v5", "Standard_B2ms", "Standard_DS2_v2")
$vmCreated = $false
foreach ($vmSize in $vmSizes) {
    Write-Info "Trying VM size: $vmSize"
    az vm create `
        --resource-group $ResourceGroupName `
        --name $VmName `
        --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest `
        --size $vmSize `
        --admin-username $AdminUsername `
        --admin-password $plainPassword `
        --nics $nicName `
        --assign-identity '[system]' `
        --output none 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "VM '$VmName' created with size $vmSize and system-assigned managed identity"
        $vmCreated = $true
        break
    }
    Write-Info "Size $vmSize not available, trying next..."
    # Clean up any partial deployment
    az vm delete --resource-group $ResourceGroupName --name $VmName --yes --output none 2>$null
}
if (-not $vmCreated) {
    Assert-AzCommand "Create VM (all sizes exhausted)"
}

# Install IIS via run command
Write-Info "Installing IIS on the VM..."
az vm run-command invoke `
    --resource-group $ResourceGroupName `
    --name $VmName `
    --command-id RunPowerShellScript `
    --scripts "Install-WindowsFeature -Name Web-Server -IncludeManagementTools" `
    --output none
Assert-AzCommand "Install IIS"
Write-Ok "IIS installed"

# ─────────────────────────────────────────────────────────
# 6. Grant VM Managed Identity → Key Vault Secrets User
# ─────────────────────────────────────────────────────────
Write-Step "6/10  Granting VM identity 'Key Vault Secrets User' role"

$vmPrincipalId = az vm identity show `
    --resource-group $ResourceGroupName --name $VmName `
    --query principalId --output tsv
Assert-AzCommand "Get VM identity"

if (-not $vmPrincipalId) {
    throw "VM managed identity principal ID is empty. VM may not have been created."
}

az role assignment create `
    --assignee-object-id $vmPrincipalId `
    --assignee-principal-type ServicePrincipal `
    --role "Key Vault Secrets User" `
    --scope $kvResourceId `
    --output none
Assert-AzCommand "Assign Key Vault Secrets User role"
Write-Ok "Role assigned to VM managed identity ($vmPrincipalId)"

# Wait for RBAC propagation
Write-Info "Waiting 30s for RBAC propagation..."
Start-Sleep -Seconds 30

# ─────────────────────────────────────────────────────────
# 7. Install Key Vault VM Extension
# ─────────────────────────────────────────────────────────
Write-Step "7/10  Installing Key Vault VM Extension"

# Write settings to a temp file to avoid PowerShell JSON escaping issues with az CLI
$kvExtSettings = @{
    secretsManagementSettings = @{
        pollingIntervalInS   = "300"
        linkOnRenewal        = $true
        requireInitialSync   = $true
        observedCertificates = @(
            @{
                url                      = "https://$keyVaultName.vault.azure.net/secrets/$CertificateName"
                certificateStoreName     = "My"
                certificateStoreLocation = "LocalMachine"
            }
        )
    }
    authenticationSettings = @{
        msiEndpoint = "http://169.254.169.254/metadata/identity/oauth2/token"
        msiClientId = ""
    }
} | ConvertTo-Json -Depth 5

$settingsFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "kv-ext-settings.json")
$kvExtSettings | Set-Content -Path $settingsFile -Encoding UTF8

az vm extension set `
    --resource-group $ResourceGroupName `
    --vm-name $VmName `
    --name KeyVaultForWindows `
    --publisher Microsoft.Azure.KeyVault `
    --version 3.0 `
    --settings "@$settingsFile" `
    --output none
$extExitCode = $LASTEXITCODE
Remove-Item -Path $settingsFile -Force -ErrorAction SilentlyContinue
if ($extExitCode -ne 0) {
    $LASTEXITCODE = $extExitCode
    Assert-AzCommand "Install Key Vault VM Extension"
}
Write-Ok "Key Vault VM Extension installed"

# ─────────────────────────────────────────────────────────
# 8. Verify certificate landed in the VM cert store
# ─────────────────────────────────────────────────────────
Write-Step "8/10  Verifying certificate in VM certificate store"

$verifyCertScript = @"
`$certs = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { `$_.Subject -like '*$fqdn*' }
if (`$certs) {
    foreach (`$c in `$certs) {
        Write-Output "FOUND|`$(`$c.Thumbprint)|`$(`$c.Subject)|`$(`$c.NotAfter)"
    }
} else {
    Write-Output "NOT_FOUND"
}
"@

$certFound = $false
$maxAttempts = 10
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    Write-Info "Waiting for extension to sync certificate (attempt $attempt/$maxAttempts)..."
    Start-Sleep -Seconds 30

    $certCheckJson = Invoke-RemoteScript -Script $verifyCertScript -RG $ResourceGroupName -VM $VmName
    $certCheckObj = $certCheckJson | ConvertFrom-Json -ErrorAction SilentlyContinue
    $certCheckResult = ""
    if ($certCheckObj -and $certCheckObj.value) {
        $certCheckResult = ($certCheckObj.value | Where-Object { $_.code -like "*StdOut*" }).message
    }

    if ($certCheckResult -like "*FOUND*") {
        $certFound = $true
        Write-Ok "Certificate found in VM cert store!"
        Write-Info $certCheckResult
        break
    }
    Write-Info "Certificate not yet in store, retrying..."
}

if (-not $certFound) {
    Write-Fail "Certificate NOT found in VM cert store after $maxAttempts attempts."
    Write-Info "Check extension logs at: C:\WindowsAzure\Logs\Plugins\Microsoft.Azure.KeyVault.KeyVaultForWindows\"
    Write-Info "Raw output: $certCheckResult"
}

# ─────────────────────────────────────────────────────────
# 9. Bind certificate to IIS (HTTPS on port 443)
# ─────────────────────────────────────────────────────────
Write-Step "9/10  Binding certificate to IIS"

if (-not $certFound) {
    Write-Fail "Skipping IIS binding - certificate not available in VM store."
} else {

$bindIisScript = @"
Import-Module WebAdministration

# Find the certificate
`$cert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { `$_.Subject -like '*$fqdn*' } |
    Sort-Object NotBefore -Descending |
    Select-Object -First 1

if (-not `$cert) {
    Write-Output "BIND_FAIL|No certificate found for $fqdn"
    exit 1
}

# Remove existing HTTPS binding if present
`$existing = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
if (`$existing) {
    Remove-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
}

# Create HTTPS binding (no SNI, bind to all IPs for testing)
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 -IPAddress '*'

# Associate the certificate
`$binding = Get-WebBinding -Name 'Default Web Site' -Protocol https
`$binding.AddSslCertificate(`$cert.Thumbprint, 'My')

# Verify
`$final = Get-WebBinding -Name 'Default Web Site' -Protocol https
Write-Output "BIND_OK|`$(`$cert.Thumbprint)|`$(`$final.bindingInformation)"
"@

$bindJson = Invoke-RemoteScript -Script $bindIisScript -RG $ResourceGroupName -VM $VmName
$bindObj = $bindJson | ConvertFrom-Json -ErrorAction SilentlyContinue
$bindResult = ""
if ($bindObj -and $bindObj.value) {
    $bindResult = ($bindObj.value | Where-Object { $_.code -like "*StdOut*" }).message
}

if ($bindResult -like "*BIND_OK*") {
    Write-Ok "IIS HTTPS binding configured!"
    Write-Info $bindResult
} else {
    Write-Fail "IIS binding failed."
    $bindStdErr = ($bindObj.value | Where-Object { $_.code -like "*StdErr*" }).message
    if ($bindStdErr) { Write-Info "StdErr: $bindStdErr" }
    Write-Info "StdOut: $bindResult"
}

} # end if certFound

# ─────────────────────────────────────────────────────────
# 10. End-to-end HTTPS test
# ─────────────────────────────────────────────────────────
Write-Step "10/10  Testing HTTPS connectivity"

if (-not $certFound) {
    Write-Fail "Skipping HTTPS test - certificate not bound to IIS."
} else {

# Self-signed cert will fail validation, so we skip cert check
Write-Info "Testing https://${fqdn}/ (self-signed, skipping cert validation)..."

try {
    # PowerShell: skip cert validation for this test
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $response = Invoke-WebRequest -Uri "https://$fqdn" -UseBasicParsing -TimeoutSec 15
    if ($response.StatusCode -eq 200) {
        Write-Ok "HTTPS connection successful! (HTTP $($response.StatusCode))"
    } else {
        Write-Fail "Unexpected status code: $($response.StatusCode)"
    }
} catch {
    Write-Fail "HTTPS connection failed: $($_.Exception.Message)"
    Write-Info "This may be expected if DNS hasn't propagated yet."
    Write-Info "Try manually: curl -k https://$fqdn"
}

} # end if certFound

# ─────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────
Write-Host ""
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "|               VERIFICATION SUMMARY                          |" -ForegroundColor Yellow
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "|  Resource Group  : $ResourceGroupName" -ForegroundColor Yellow
Write-Host "|  Key Vault       : $keyVaultName" -ForegroundColor Yellow
Write-Host "|  VM              : $VmName" -ForegroundColor Yellow
Write-Host "|  Public IP       : $publicIp" -ForegroundColor Yellow
Write-Host "|  FQDN            : $fqdn" -ForegroundColor Yellow
Write-Host "|  Certificate     : $CertificateName" -ForegroundColor Yellow
Write-Host "|  Thumbprint      : $certThumbprint" -ForegroundColor Yellow
Write-Host "|" -ForegroundColor Yellow
Write-Host "|  Test URL        : https://$fqdn" -ForegroundColor Yellow
Write-Host "|  RDP             : mstsc /v:$publicIp" -ForegroundColor Yellow
Write-Host "|  RDP User        : $AdminUsername" -ForegroundColor Yellow
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Yellow

# ─────────────────────────────────────────────────────────
# Cleanup prompt
# ─────────────────────────────────────────────────────────
if (-not $SkipCleanup) {
    Write-Host ""
    $cleanup = Read-Host "Delete all resources in '$ResourceGroupName'? (y/N)"
    if ($cleanup -eq "y") {
        Write-Step "Cleaning up"
        az group delete --name $ResourceGroupName --yes --no-wait --output none
        Write-Ok "Resource group deletion initiated (running in background)"
    } else {
        Write-Info "Resources kept. Delete later with: az group delete --name $ResourceGroupName --yes"
    }
} else {
    Write-Info "SkipCleanup set. Delete later with: az group delete --name $ResourceGroupName --yes"
}
