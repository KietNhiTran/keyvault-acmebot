param(
    [string[]]$Locations = @("australiaeast", "eastus2", "westus2", "centralus", "northeurope", "westeurope", "southeastasia"),
    [string[]]$PreferredSkus = @("Standard_B2s", "Standard_B2ms", "Standard_B2als_v2", "Standard_D2s_v3", "Standard_D2as_v5", "Standard_DS2_v2")
)

foreach ($loc in $Locations) {
    Write-Host "Checking $loc ..." -ForegroundColor Cyan -NoNewline
    $skus = az vm list-skus --location $loc --resource-type virtualMachines --output json 2>$null | ConvertFrom-Json

    if (-not $skus) {
        Write-Host " no data" -ForegroundColor Yellow
        continue
    }

    foreach ($preferred in $PreferredSkus) {
        $match = $skus | Where-Object { $_.name -eq $preferred }
        if ($match) {
            $restricted = $match.restrictions | Where-Object { $_.type -eq "Location" }
            if (-not $restricted) {
                Write-Host ""
                Write-Host "  AVAILABLE: $preferred in $loc" -ForegroundColor Green
                Write-Host "RESULT|$loc|$preferred"
                exit 0
            }
        }
    }
    Write-Host " none of preferred SKUs available" -ForegroundColor Yellow
}

Write-Host "No available SKU found in any checked region" -ForegroundColor Red
exit 1
