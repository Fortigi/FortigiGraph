function Set-AccessPackage {
    [cmdletbinding()]
    Param
    (
        [Alias("Id")]
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,
        [Parameter(Mandatory = $true)]
        $Updates
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/$ObjectId"
    $Body = $Updates 

    $ReturnValue = Invoke-PatchRequest -URI $URI -Body $Body
    return $ReturnValue
}