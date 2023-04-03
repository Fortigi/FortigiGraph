function Confirm-AccessPackagePolicy {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $Policy
    )

    $AccessPackageId = $Policy.accessPackageId
    if ($null -eq $Policy.accessPackageId) {
        throw "Policy doesn't contain accessPackageId"
    }
    
    $DisplayName = $Policy.displayName
    if ($null -eq $Policy.accessPackageId) {
        throw "Policy doesn't contain displayName"
    }

    [array]$AccessPackagesPolicies = Get-AccessPackagesPolicy 
    [array]$AccessPackagesPolicy = $AccessPackagesPolicies | Where-object { ($_.displayName -eq $Policy.displayName) -and ($_.accessPackageId -eq $Policy.accessPackageId) }


    if ($AccessPackagesPolicy.count -eq 1) {
        Write-Host "Confirmed AccessPackagePolicy: $DisplayName exists" -ForegroundColor Green
        Write-Host "Updating policy: $DisplayName" -ForegroundColor Yellow
        Set-AccessPackagePolicy -Policy $Policy -PolicyId $AccessPackagesPolicy.id
    }
    elseif ($AccessPackagesPolicy.count -gt 1) {
        throw "More then one policy found with DisplayName: $DisplayName"
    }
    else {
        Write-Host "Creating AccessPackagePolicy: $DisplayName" -ForegroundColor Yellow
        New-AccessPackagePolicy -Policy $Policy
    }

    [array]$Policies = Get-AccessPackagesPolicy 
    [array]$Policy = $Policies | Where-object { ($_.displayName -eq $Policy.displayName) -and ($_.accessPackageId -eq $Policy.accessPackageId) }

    Return $Policy
}