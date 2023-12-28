function Confirm-FGCatalog {
    [alias("Confirm-Catalog")]
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogName,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$IsExternallyVisible
    )

    [array]$Catalogs = Get-FGCatalog
    [array]$Catalog = $Catalogs | Where-object { $_.displayName -eq $CatalogName }
    if ($Catalog.count -eq 1) {
        Write-Host "Confirmed Cataloge: $CatalogName exists" -ForegroundColor Green
    }
    elseif ($Catalog.count -gt 1) {
        throw "More then one cataloge found for CatalogeName: $CatalogName"
    }
    else {
        Write-Host "Adding cataloge: $CatalogName" -ForegroundColor Yellow
        New-FGCatalog -CatalogeName $CatalogName -Description $Description -IsExternallyVisible $IsExternallyVisible
    }

    [array]$Catalogs = Get-FGCatalog
    [array]$Catalog = $Catalogs | Where-object { $_.displayName -eq $CatalogName }

    Return $Catalog
}