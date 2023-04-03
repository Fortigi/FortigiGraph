function Get-AccessToken {
    Param(
        [Parameter(Mandatory = $True)]
        [System.String]$ClientId,
        [Parameter(Mandatory = $True)]
        [System.String]$ClientSecret,       
        [Parameter(Mandatory = $True)]
        [System.String]$TenantId,
        [Parameter()]
        $Resource = "https://graph.microsoft.com/"              
    )

    $Body = @{
        client_id     = $ClientID
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
        resource      = $Resource
    }
    $URI = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    $TokenRequest = Invoke-RestMethod -Method Post -Uri $URI -Body $Body
   
    $AccessToken = $TokenRequest.access_token
    If ($AccessToken) {
        $global:AccessToken = $AccessToken
        $global:ClientId = $ClientId
        $global:ClientSecret = $ClientSecret
        $global:TenantId = $TenantId
        
    }
    If (!$AccessToken) { 
        Throw "Error retrieving Graph Access Token. Please validate parameter input for -ClientID, -ClientSecret and -TenantId and check API permissions of the (App Registration) client in AzureAD" 
    }
} 