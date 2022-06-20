function New-MsGraphGroup {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $Group
    )

    $URI = "https://graph.microsoft.com/beta/groups"
    $Body = $Group

    $ReturnValue = Invoke-MsGraphPostRequest -URI $URI -Body $Body
    return $ReturnValue
}