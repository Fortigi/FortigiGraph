function Get-UserMailFolder {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$id
    )

    $URI = "https://graph.microsoft.com/beta/users/$id/mailFolders"
   

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue


}