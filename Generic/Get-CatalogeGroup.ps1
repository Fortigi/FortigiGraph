function Get-CatalogeGroup {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogId
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs/$CatalogId/accessPackageResources"

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
}