function Set-MsGraphUser {
    [cmdletbinding()]
    Param
    (
        [Alias("UserId", "Id")]
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,
        [Parameter(Mandatory = $true)]
        $Updates
    )

    $URI = "https://graph.microsoft.com/beta/users/$ObjectId"
    $Body = $Updates 

    $ReturnValue = Invoke-MsGraphPatchRequest -URI $URI -Body $Body
    return $ReturnValue
}