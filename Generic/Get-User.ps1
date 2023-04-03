function Get-User {
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
        [string]$id,
                
        [Parameter(Mandatory = $false)]
        [ValidateSet('Member', 'Guest')]
        [string]$UserType,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [bool]$IncludeManager
    )

    $URI = 'https://graph.microsoft.com/beta/users'

    If ($userPrincipalName) {
        $URI = $URI + '?$filter=' + "userPrincipalName eq '$userPrincipalName'"
    }
    
    If ($id) {
        if ($URI.Contains('?$filter=')) {
            $URI = $URI + " and id eq '$id'"
        } 
        else {
            $URI = $URI + '?$filter=' + "id eq '$id'"
        }
    }

    If ($UserType) {
        if ($URI.Contains('?$filter=')) {
            $URI = $URI + " and userType eq '$UserType'"
        }
        else {
            $URI = $URI + '?$filter=' + "userType eq '$UserType'"
        }
    }

    If ($includeManager) {
        if ($URI.Contains("?")) {
            $URI = $URI + '&$expand=manager'
        }
        else {
            $URI = $URI + '?$expand=manager'
        }
    }

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue


}