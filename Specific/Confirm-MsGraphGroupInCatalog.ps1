function Confirm-MsGraphGroupInCatalog {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $Catalog,
        [Parameter(Mandatory = $true)]
        $GroupName
    )

    $CatalogId = $Catalog.id

    [array]$CatalogeGroups = Get-MsGraphCatalogeGroup -CatalogId $CatalogId
    [array]$CatalogeGroup = $CatalogeGroups | Where-Object { $_.displayName -eq $GroupName }

    $CatalogeName = $Catalog.displayName

    if ($CatalogeGroup.count -eq 1) {
        Write-Host "Confirmed GroupInCatalog: $GroupName is in cataloge: $CatalogeName" -ForegroundColor Green
    }
    elseif ($CatalogeGroup.count -gt 1) {
        throw "More then one group found for group: $GroupName"
    }
    else {
        Write-Host "Adding GroupInCatalog: $GroupName to cataloge: $CatalogeName" -ForegroundColor Yellow
        Add-MsGraphGroupToCatalog -CatalogId $CatalogId -GroupName $GroupName
    }

    [array]$CatalogeGroups = Get-MsGraphCatalogeGroup -CatalogId $CatalogId
    $CatalogeGroup = $CatalogeGroups | Where-Object { $_.displayName -eq $GroupName }

    return $CatalogeGroup
}