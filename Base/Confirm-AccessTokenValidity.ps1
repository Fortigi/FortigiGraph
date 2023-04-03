function Confirm-AccessTokenValidity {
    
    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
    }
    
    $TokenDecoded = Get-AccessTokenDetail

    [Int64]$Ctime=$TokenDecoded.exp
    [datetime]$Epoch = '1970-01-01 00:00:00'
    [datetime]$ResultUTC = $epoch.AddSeconds($Ctime)
    [datetime]$NowUTC = Get-Date -AsUTC


    If ($ResultUTC -gt $NowUTC) {

        If ($Global:DebugMode.Contains('T')) {
            $ValidUntil = $ResultUTC - $NowUTC
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Get-AccessTokenDetail" -ForegroundColor Blue
            Write-Host ("Access token: valid for: " + $ValidUntil.Minutes) -ForegroundColor Blue
        }
        return $true
    }
    else {
        If ($Global:DebugMode.Contains('T')) {
            $ValidUntil = $ResultUTC - $NowUTC
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Get-AccessTokenDetail" -ForegroundColor Blue
            Write-Host "Access token no longer valid."  -ForegroundColor Blue
        }
        return $false
    }

}