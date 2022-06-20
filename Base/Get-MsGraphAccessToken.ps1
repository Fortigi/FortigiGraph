function Get-MsGraphAccessToken {
    Param(
        [Parameter(Mandatory = $True)]
        [System.String]$ClientId,
        [Parameter(Mandatory = $True)]
        [System.String]$ClientSecret,       
        [Parameter(Mandatory = $True)]
        [System.String]$TenantId            
    )

    $Body = @{client_id = $ClientID; client_secret = $ClientSecret; grant_type = "client_credentials"; resource = "https://graph.microsoft.com"; }
    $OAuthReq = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" -Body $Body
    $AccessToken = $OAuthReq.access_token
    If ($AccessToken) {
        $global:AccessToken = $AccessToken
    }
    If (!$AccessToken) { 
        Throw "Error retrieving Graph Access Token. Please validate parameter input for -ClientID, -ClientSecret and -TenantId and check API permissions of the (App Registration) client in AzureAD" 
    }
} 