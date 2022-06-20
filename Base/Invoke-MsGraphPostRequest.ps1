function Invoke-MsGraphPostRequest {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI,
        [Parameter(Mandatory = $true)]
        $Body
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-MsGraphAccessToken or Get-MsGraphAccessTokenInteractive before running this function."
    }
    Else {
        $AccessToken = $Global:AccessToken
    }
    
    $Body = $Body | ConvertTo-Json -Depth 10

    Try {
        $Result = Invoke-RestMethod -Method Post -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" } -Body $Body -ContentType "application/json"
    }
    Catch {
        Throw $_
    }
    
    return $Result.value
}