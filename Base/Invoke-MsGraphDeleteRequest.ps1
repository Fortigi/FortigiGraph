function Invoke-MsGraphDeleteRequest {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-MsGraphAccessToken or Get-MsGraphAccessTokenInteractive before running this function."
    }
    Else {
        $AccessToken = $Global:AccessToken
    }

    If ($Global:DebugMode.Contains('D')) {
        Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
        Write-Host "Invoke-MsGraphDeleteRequest" -ForegroundColor Blue
        Write-Host $URI -ForegroundColor Blue
    }

    Try {
        $Result = Invoke-RestMethod -Method DELETE -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" }
        $Result
    }
    Catch {
        Throw $_
    }
    
    return $Result
}