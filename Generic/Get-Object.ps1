function Get-Object {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $URI = "https://graph.microsoft.com/beta/directoryObjects/$id"

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
   
}