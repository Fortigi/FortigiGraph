function Get-FGConnectedOrganization {
    [alias("Get-ConnectedOrganization")]
    [cmdletbinding()]
    Param()

    $URI = 'https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/connectedOrganizations'

    $ReturnValue = Invoke-FGGetRequest -URi $URI
    return $ReturnValue

}