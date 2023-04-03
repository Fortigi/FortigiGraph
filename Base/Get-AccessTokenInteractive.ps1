function Get-AccessTokenInteractive {
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [System.String]$TenantId,
        [Parameter(Mandatory = $false)]
        [System.String]$ClientId,
        [Parameter()]
        $Resource = "https://graph.microsoft.com/"         
    )
    
    #Source: https://blog.simonw.se/getting-an-access-token-for-azuread-using-powershell-and-device-login-flow/
    #Some minor adjustments

    If (!($ClientId)) {
        $ClientId = '1950a258-227b-4e31-a9cf-717495945fc2' #Microsoft Azure PowerShell
        #$ClientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c' #Office...
    }


    $Uri = "https://login.microsoftonline.com/$TenantID/oauth2/devicecode"
    $Body = @{
        client_id = $ClientId
        resource  = $Resource
    }
    
    $DeviceCodeRequest = Invoke-RestMethod -Method Post -Uri $URI -Body $Body
    Write-Host $DeviceCodeRequest.message -ForegroundColor Yellow
    pause

    $Uri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    $Body = @{
        grant_type = "urn:ietf:params:oauth:grant-type:device_code"
        code       = $DeviceCodeRequest.device_code
        client_id  = $ClientId
    }
    $TokenRequest = Invoke-RestMethod -Method Post -Uri $URI -Body $Body
    $AccessToken = $TokenRequest.access_token
    
    If ($AccessToken) {
        $global:AccessToken = $TokenRequest.access_token
        $global:RefreshToken = $TokenRequest.refresh_token
        $global:ClientId = $ClientId
        $global:TenantId = $TenantId
    }
    If (!$AccessToken) { 
        Throw "Error retrieving Graph Access Token. Check API permissions of the (App Registration) in AzureAD" 
    }
}