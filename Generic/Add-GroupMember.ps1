function Add-GroupMember {
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


    $URI = 'https://graph.microsoft.com/beta/groups/' + $Id + '/members/$ref'

    $Body = @{
        '@odata.id' = "https://graph.microsoft.com/beta/directoryObjects/$MemberId"
    }

    $ReturnValue = Invoke-PostRequest -URI $URI -Body $Body
    return $ReturnValue

}