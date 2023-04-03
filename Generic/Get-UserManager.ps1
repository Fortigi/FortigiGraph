function Get-UserManager {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$id
    )

    $URI = 'https://graph.microsoft.com/beta/users/'+$id+'/manager'
    
    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue


}