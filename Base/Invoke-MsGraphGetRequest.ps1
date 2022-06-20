function Invoke-MsGraphGetRequest {
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
    
    If ($Global:DebugMode.Contains('G')) {
        Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
        Write-Host "Invoke-MsGraphGetRequest" -ForegroundColor Blue
        Write-Host $URI -ForegroundColor Blue
    }

    $ReturnValue = $Null
    Try {
        $Result = Invoke-RestMethod -Method Get -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" }
    }
    Catch {
        Throw $_
    }

    #Most get requests will return results in .value but not all.. grr... watch out.. having the propery .value doesn't mean it has a value
    if ($Result.PSobject.Properties.name -match "value") {
        $ReturnValue = $Result.value
    }
    else {
        $ReturnValue += $Result
    }

    #By default you only get 100 results... its paged
    While ($Result.'@odata.nextLink') {
        Try {
            $Result = Invoke-RestMethod -Method Get -Uri $Result.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $AccessToken" }
        }
        Catch {
            Throw $_
        }
        $ReturnValue += $Result.value
    }

    return $ReturnValue
}