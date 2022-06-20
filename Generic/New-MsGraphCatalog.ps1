function New-MsGraphCatalog {
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

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageCatalogs"

    $Body = @{
        displayName         = $CatalogeName
        description         = $description
        isExternallyVisible = $isExternallyVisible
    }

    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
   
}