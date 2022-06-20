function Get-MsGraphCatalogeGroup {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogId
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs/$CatalogId/accessPackageResources"

    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue
}