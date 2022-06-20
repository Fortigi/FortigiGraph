function Get-MsGraphObject {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $URI = "https://graph.microsoft.com/beta/directoryObjects/$id"

    $ReturnValue = Invoke-MsGraphGetRequest -URi $URI
    return $ReturnValue
   
}