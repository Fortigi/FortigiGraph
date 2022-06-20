function Get-MsGraphUser {
    [cmdletbinding()]
    Param
    (
        #UPN or userPrincipalName can be specified.. not required. but if specified it must have a value.
        [Alias("UPN")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$userPrincipalName,
        
        [Alias("ObjectId")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$id
    )

    If ($userPrincipalName) {
        $URI = 'https://graph.microsoft.com/beta/users?$filter=' + "userPrincipalName eq '$userPrincipalName'"
    }
    Elseif ($id) {
        $URI = 'https://graph.microsoft.com/beta/users?$filter=' + "id eq '$id'"
    }
    Else {
        $URI = 'https://graph.microsoft.com/beta/users'
    }

    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue


}