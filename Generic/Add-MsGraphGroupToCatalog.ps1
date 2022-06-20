function Add-MsGraphGroupToCatalog {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,
        [Parameter(Mandatory = $true)]
        [string]$GroupName
    )

    $GroupObject = Get-MsGraphGroup -GroupName $GroupName

    $Body = @{
        catalogId             = $CatalogId
        requestType           = "AdminAdd"
        accessPackageResource = @{
            originId     = $GroupObject.id
            originSystem = "AadGroup"         
        }
    }

    #It takes a little time before a group can be added to a cataloge.. so sleep..
    Start-sleep -s 45
    
    $URI = "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/accessPackageResourceRequests"
    
    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
}