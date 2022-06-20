function Invoke-MsGraphPatchRequest {
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

    If ($Global:DebugMode.Contains('P')) {
        Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
        Write-Host "Invoke-MsGraphPatchRequest" -ForegroundColor Blue
        Write-Host $URI -ForegroundColor Blue
        Write-Host $Body -ForegroundColor Blue
    }

    Try {
        $Result = Invoke-RestMethod -Method PATCH -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" } -Body $Body -ContentType "application/json"
    }
    Catch {
        Throw $_
    }
    
    return $Result.value
}