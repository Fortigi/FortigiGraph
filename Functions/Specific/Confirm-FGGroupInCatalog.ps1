function Confirm-FGGroupInCatalog {
    [alias("Confirm-GroupInCatalog")]
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $Catalog,
        [Parameter(Mandatory = $true)]
        $GroupName
    )

    $CatalogId = $Catalog.id

    [array]$CatalogeGroups = Get-FGCatalogeGroup -CatalogId $CatalogId
    [array]$CatalogeGroup = $CatalogeGroups | Where-Object { $_.displayName -eq $GroupName }

    $CatalogeName = $Catalog.displayName

    if ($CatalogeGroup.count -eq 1) {
        Write-Host "Confirmed GroupInCatalog: $GroupName is in catalog: $CatalogeName" -ForegroundColor Green
    }
    elseif ($CatalogeGroup.count -gt 1) {
        throw "More than one group found for group: $GroupName"
    }
    else {
        Write-Host "Adding GroupInCatalog: $GroupName to catalog: $CatalogeName" -ForegroundColor Yellow
        Add-FGGroupToCatalog -CatalogId $CatalogId -GroupName $GroupName
    }

    [array]$CatalogeGroups = Get-FGCatalogeGroup -CatalogId $CatalogId
    $CatalogeGroup = $CatalogeGroups | Where-Object { $_.displayName -eq $GroupName }

    return $CatalogeGroup
}