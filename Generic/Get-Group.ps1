function Get-Group {
    [cmdletbinding()]
    Param
    (
        [Alias("GroupName","Name")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName,
        [Alias("ObjectId")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Id
    )

    If ($DisplayName) {
        $URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "displayName eq '$DisplayName'"
    }
    Elseif ($id) {
        $URI = 'https://graph.microsoft.com/beta/groups?$filter=' + "id eq '$id'"
    }
    Else {
        $URI = 'https://graph.microsoft.com/beta/groups'
    }

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue

}