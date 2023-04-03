function Invoke-PutRequest {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI,
        [Parameter(Mandatory = $true)]
        $Body
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
    }
    Else {
        $AccessToken = $Global:AccessToken
    }
    
    $Body = $Body | ConvertTo-Json -Depth 10

    If ($Global:DebugMode) {
        If ($Global:DebugMode.Contains('P')) {
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Invoke-PatchRequest" -ForegroundColor Blue
            Write-Host $URI -ForegroundColor Blue
            Write-Host $Body -ForegroundColor Blue
        }
    }

     #Check if Access token is expired, if so get new one.
     $TokenIsStillValid = Confirm-AccessTokenIsStillValid
     if (!($TokenIsStillValid)) {
         
         If ($Global:DebugMode.Contains('P')) {
             Write-Host "Access Token Expired, getting new one" -ForegroundColor Blue
         }
     
         If ($global:ClientSecret) {
             Get-AccessToken -ClientID $Global:ClientID -TenantId $Global:TenantId -ClientSecret $global:ClientSecret
         }
         Elseif ($global:RefreshToken) {
             Get-AccessTokenWithRefreshToken -ClientID $Global:ClientID -TenantId $Global:TenantId -RefreshToken $global:RefreshToken
         } 
         Else {
             Throw "Access Token expired."   
         }
     
     }

    Try {
        #Run request
        $Result = Invoke-RestMethod -Method Put -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" } -Body $Body -ContentType "application/json"
    }
    Catch {
        Throw $_
    }
    
    if ($Result.PSobject.Properties.name -match "value") {
        $ReturnValue = $Result.value
    }
    else {
        $ReturnValue += $Result
    }

    return $ReturnValue
}