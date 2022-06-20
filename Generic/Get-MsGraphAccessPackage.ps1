function Get-MsGraphAccessPackage {
    [cmdletbinding()]
    Param
    (
        [Alias("Name")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$displayName,
        [Alias("ObjectId")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$id
    )

    If ($displayName) {
        $URI = 'https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?$filter=' + "displayName eq '$displayName'"
    }
    Elseif ($id) {
        $URI = 'https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages?$filter=' + "id eq '$id'"
    }
    Else {
        $URI = 'https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages'
    }

    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue
}