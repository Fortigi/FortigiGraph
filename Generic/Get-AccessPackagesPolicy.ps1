function Get-AccessPackagesPolicy {

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies"
    
    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
}