function Get-FGAccessPackagesPolicy {
    [alias("Get-AccessPackagesPolicy")]
    [cmdletbinding()]
    Param()

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies"
    
    $ReturnValue = Invoke-FGGetRequest -URi $URI
    return $ReturnValue
}