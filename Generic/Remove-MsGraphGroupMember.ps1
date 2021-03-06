function Remove-MsGraphGroupMember {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [Alias("MemberObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$MemberId
    )


    $URI = 'https://graph.microsoft.com/beta/groups/'+$Id+'/members/'+$MemberId+'/$ref'

    $Result = Invoke-MsGraphDeleteRequest -URI $URI
    $Result
   
}