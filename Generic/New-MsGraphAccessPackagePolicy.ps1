function New-MsGraphAccessPackagePolicy {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $Policy
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageAssignmentPolicies"
    $Body = $Policy 
    
    #It takes a little time before a group can be added to a policy.. so sleep..
    Start-sleep -s 45

    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
}