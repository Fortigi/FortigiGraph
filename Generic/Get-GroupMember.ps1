function Get-GroupMember {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id
    )


    $URI = "https://graph.microsoft.com/beta/groups/$Id/members"

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
   
}