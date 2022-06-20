function Add-MsGraphGroupToAccessPackage {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageID,
        [Parameter(Mandatory = $true)]
        [string]$GroupID,
        [Parameter(Mandatory = $true)]
        [string]$CatalogeGroupID
    )

    $Body = @{
        accessPackageResourceRole  = @{
            originId              = ("Member_" + $GroupID)
            displayName           = "Member"
            originSystem          = "AadGroup"
            accessPackageResource = @{
                id           = $CatalogeGroupID
                resourceType = "O365 Group"
                originId     = $GroupID
                originSystem = "AadGroup"
            }
        }
        accessPackageResourceScope = @{
            originId     = $GroupID
            originSystem = "AadGroup"
        }
    }
    
    #It takes a little time before a group can be added to a cataloge.. so sleep..
    Start-sleep -s 45
    
    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackages/$AccessPackageID/accessPackageResourceRoleScopes"
    
    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
}