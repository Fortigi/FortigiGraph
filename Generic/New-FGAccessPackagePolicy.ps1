function New-FGAccessPackagePolicy {
    [alias("New-AccessPackagePolicy")]
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

    $ReturnValue = Invoke-FGPostRequest -URI $URI -Body $Body
    return $ReturnValue
}