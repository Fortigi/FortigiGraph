function New-MsGraphAccessPackage {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages"

    $Body = @{
        catalogId   = $CatalogId
        displayName = $DisplayName
        description = $Description
    }
    
    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
}