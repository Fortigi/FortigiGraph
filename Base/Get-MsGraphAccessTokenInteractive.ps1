function Get-MsGraphAccessTokenInteractive {
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [System.String]$TenantId,
        [Parameter(Mandatory = $False)]
        [System.String]$ClientId,
        [Parameter()]
        $Resource = "https://graph.microsoft.com/"         
    )
    
    #Source: https://blog.simonw.se/getting-an-access-token-for-azuread-using-powershell-and-device-login-flow/
    #Some minor adjustments

    If (!($ClientId)) {
        $ClientId = '1950a258-227b-4e31-a9cf-717495945fc2' #Micrsooft Azure PowerShell
        #$ClientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c' #Office...
    }

    $DeviceCodeRequestParams = @{
        Method = 'POST'
        Uri    = "https://login.microsoftonline.com/$TenantID/oauth2/devicecode"
        Body   = @{
            client_id = $ClientId
            resource  = $Resource
        }
    }

    $DeviceCodeRequest = Invoke-RestMethod @DeviceCodeRequestParams
    Write-Host $DeviceCodeRequest.message -ForegroundColor Yellow
    pause

    $TokenRequestParams = @{
        Method = 'POST'
        Uri    = "https://login.microsoftonline.com/$TenantId/oauth2/token"
        Body   = @{
            grant_type = "urn:ietf:params:oauth:grant-type:device_code"
            code       = $DeviceCodeRequest.device_code
            client_id  = $ClientId
        }
    }
    $TokenRequest = Invoke-RestMethod @TokenRequestParams
    $AccessToken = $TokenRequest.access_token

    If ($AccessToken) {
        $global:AccessToken = $AccessToken
    }
    If (!$AccessToken) { 
        Throw "Error retrieving Graph Access Token. Check API permissions of the (App Registration) in AzureAD" 
    }
}