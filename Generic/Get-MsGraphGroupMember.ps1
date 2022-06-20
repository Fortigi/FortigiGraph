function Get-MsGraphGroupMember {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id
    )


    $URI = "https://graph.microsoft.com/beta/groups/$Id/members"

    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue
   
}