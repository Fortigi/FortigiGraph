function Get-MsGraphAccessPackagesPolicy {

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies"
    
    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue
}