function Set-Device {
    [cmdletbinding()]
    Param
    (
        [Alias("Id")]
        [Parameter(Mandatory = $true)]
        [string]$DeviceId,
        [Parameter(Mandatory = $true)]
        $Updates
    )

    $URI = "https://graph.microsoft.com/beta/devices/$DeviceId"
    $Body = $Updates 

    $ReturnValue = Invoke-PatchRequest -URI $URI -Body $Body
    return $ReturnValue
}