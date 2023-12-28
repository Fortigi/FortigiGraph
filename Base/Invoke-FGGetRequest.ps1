function Invoke-FGGetRequest {
    [alias("Invoke-FGGetRequest")]
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
    }
    Else {
        $AccessToken = $Global:AccessToken
    }
    
    If ($Global:DebugMode) {
        If ($Global:DebugMode.Contains('G')) {
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Invoke-FGGetRequest" -ForegroundColor Blue
            Write-Host $URI -ForegroundColor Blue
        }
    }

    #Check if Access token is expired, if so get new one.
    $TokenIsStillValid = Confirm-FGAccessTokenValidity
    if (!($TokenIsStillValid)) {
        
        If ($Global:DebugMode.Contains('G')) {
            Write-Host "Access Token Expired, getting new one" -ForegroundColor Blue
        }
    
        If ($global:ClientSecret) {
            Get-FGAccessToken -ClientID $Global:ClientID -TenantId $Global:TenantId -ClientSecret $global:ClientSecret
        }
        Elseif ($global:RefreshToken) {
            Get-FGAccessTokenWithRefreshToken -ClientID $Global:ClientID -TenantId $Global:TenantId -RefreshToken $global:RefreshToken
        } 
        Else {
            Throw "Access Token expired."   
        }
    
    }

    $ReturnValue = $Null
    Try {
        #Run request
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