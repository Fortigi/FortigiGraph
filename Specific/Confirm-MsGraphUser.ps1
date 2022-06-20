function Confirm-MsGraphUser {
    [cmdletbinding()]
    Param
    (
        [Alias("UPN")]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$userPrincipalName
    )

    #Check if group exists only once
    [array]$User = Get-MsGraphUser -UserPrincipalName $userPrincipalName
    if ($User.count -eq 1) {
        Write-Host "Confirmed User exists: $userPrincipalName" -ForegroundColor Green
    }
    elseif ($Group.count -gt 1) {
        throw "More then one user found with upn: $userPrincipalName"
    }
    else {
        Write-Host ("User: " + $userPrincipalName + " was not found.") -ForegroundColor Red
    }

    return $User
   
}