function Remove-Device {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $URI = "https://graph.microsoft.com/beta/devices/$Id"
    $Result = Invoke-DeleteRequest -URI $URI
    $Result
}