function Confirm-MsGraphCatalog {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogeName,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$IsExternallyVisible
    )

    [array]$Cataloges = Get-MsGraphCatalog
    [array]$Cataloge = $Cataloges | Where-object { $_.displayName -eq $CatalogeName }
    if ($Cataloge.count -eq 1) {
        Write-Host "Confirmed Cataloge: $CatalogeName exists" -ForegroundColor Green
    }
    elseif ($Cataloge.count -gt 1) {
        throw "More then one cataloge found for CatalogeName: $CatalogeName"
    }
    else {
        Write-Host "Adding cataloge: $CatalogeName" -ForegroundColor Yellow
        New-MsGraphCatalog -CatalogeName $CatalogeName -Description $Description -IsExternallyVisible $IsExternallyVisible
    }

    [array]$Cataloges = Get-MsGraphCatalog
    [array]$Cataloge = $Cataloges | Where-object { $_.displayName -eq $CatalogeName }

    Return $Cataloge
}