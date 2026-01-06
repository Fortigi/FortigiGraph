function Invoke-FGGetRequest {
    [alias("Invoke-GetRequest")]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
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

        If ($Global:DebugMode) {
            If ($Global:DebugMode.Contains('G')) {
                Write-Host "Access Token Expired, getting new one" -ForegroundColor Blue
            }
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

    # Get the current (potentially refreshed) access token
    $AccessToken = $Global:AccessToken

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
        # Check token validity before fetching next page (token may expire during long pagination)
        $TokenIsStillValid = Confirm-FGAccessTokenValidity
        if (!($TokenIsStillValid)) {
            If ($Global:DebugMode -and $Global:DebugMode.Contains('G')) {
                Write-Host "Access Token Expired during pagination, getting new one" -ForegroundColor Blue
            }

            If ($global:ClientSecret) {
                Get-FGAccessToken -ClientID $Global:ClientID -TenantId $Global:TenantId -ClientSecret $global:ClientSecret
            }
            Elseif ($global:RefreshToken) {
                Get-FGAccessTokenWithRefreshToken -ClientID $Global:ClientID -TenantId $Global:TenantId -RefreshToken $global:RefreshToken
            }
            Else {
                Throw "Access Token expired during pagination."
            }

            # Update local token variable with refreshed token
            $AccessToken = $Global:AccessToken
        }

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