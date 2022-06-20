function Confirm-MsGraphAccessPackageResource {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $AccessPackage,
        [Parameter(Mandatory = $true)]
        $Group,
        [Parameter(Mandatory = $true)]
        $CatalogeGroup
    )

    $GroupDisplayName = $Group.displayName
    $AccessPackageName = $AccessPackage.displayName

    $AccessPackageResourceRoles = Get-MsGraphAccessPackagesResource -AccessPackageID $AccessPackage.id 
    If ($AccessPackageResourceRoles.accessPackageResourceRoleScopes.accessPackageResourceScope.originId -eq $Group.id) {
        Write-Host "Confirmed AccessPackageResource Group: $GroupDisplayName is linked to $AccessPackageName" -ForegroundColor Green
    }
    Else {
        Write-Host "Adding AccessPackageResource Group: $GroupDisplayName to Access Package: $AccessPackageName" -ForegroundColor Yellow
        Add-MsGraphGroupToAccessPackage -AccessPackageID $AccessPackage.id -GroupId $Group.id -CatalogeGroupID $CatalogeGroup.id
    }

    $Result = Get-MsGraphAccessPackagesResource -AccessPackageID $AccessPackage.id
    return $Result
}