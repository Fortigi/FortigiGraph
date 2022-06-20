function Set-MsGraphGroup {
    [cmdletbinding()]
    Param
    (
        [Alias("GroupID", "Id")]
        [Parameter(Mandatory = $true)]
        [string]$ObjectId,
        [Parameter(Mandatory = $true)]
        $Updates
    )

    $URI = "https://graph.microsoft.com/beta/groups/$ObjectId"
    $Body = $Updates 

    $ReturnValue = Invoke-MsGraphPatchRequest -URI $URI -Body $Body
    return $ReturnValue
}