function Add-MsGraphGroupMember {
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
    
    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
   
}