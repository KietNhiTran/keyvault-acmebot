$fqdn = "kviis77d0.australiaeast.cloudapp.azure.com"

function Invoke-RemoteScript {
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

Write-Host "=== Testing Invoke-RemoteScript helper (step 8 fix) ==="
$certCheckJson = Invoke-RemoteScript -Script $verifyCertScript -RG "rg-kviis-77d0" -VM "vm-kviis-77d0"
$certCheckObj = $certCheckJson | ConvertFrom-Json -ErrorAction SilentlyContinue
$certCheckResult = ""
if ($certCheckObj -and $certCheckObj.value) {
    $certCheckResult = ($certCheckObj.value | Where-Object { $_.code -like "*StdOut*" }).message
}
Write-Host "  Result: $certCheckResult"
if ($certCheckResult -like "*FOUND*") {
    Write-Host "  SUCCESS - cert found!" -ForegroundColor Green
} else {
    Write-Host "  FAIL - cert not found" -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Testing IIS binding script (step 9 fix) ==="
$bindIisScript = @"
Import-Module WebAdministration
`$cert = Get-ChildItem -Path Cert:\LocalMachine\My |
    Where-Object { `$_.Subject -like '*$fqdn*' } |
    Sort-Object NotBefore -Descending |
    Select-Object -First 1
if (`$cert) {
    `$binding = Get-WebBinding -Name 'Default Web Site' -Protocol https -ErrorAction SilentlyContinue
    if (`$binding) {
        Write-Output "BIND_OK|`$(`$cert.Thumbprint)|binding exists"
    } else {
        Write-Output "BIND_CHECK|cert found but no HTTPS binding yet"
    }
} else {
    Write-Output "BIND_FAIL|No certificate found"
}
"@

$bindJson = Invoke-RemoteScript -Script $bindIisScript -RG "rg-kviis-77d0" -VM "vm-kviis-77d0"
$bindObj = $bindJson | ConvertFrom-Json -ErrorAction SilentlyContinue
$bindResult = ""
if ($bindObj -and $bindObj.value) {
    $bindResult = ($bindObj.value | Where-Object { $_.code -like "*StdOut*" }).message
}
Write-Host "  Result: $bindResult"
