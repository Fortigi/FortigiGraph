function Use-ExistingMSALToken {
    Param(
        [Parameter(Mandatory = $True)]
        $Token            
    )

    #Example
    #Install-Module MSAL.ps
    #$Token = Get-MsalToken -ClientId 1950a258-227b-4e31-a9cf-717495945fc2
    #Use-ExistingMSALToken -Token $Token

    $global:AccessTokenObject = $Token
    $global:AccessToken = $Token.AccessToken
    $AccessTokenDetail = Get-AccessTokenDetail
    $global:TenantId = $AccessTokenDetail.tid
    $global:ClientId = $AccessTokenDetail.appid    
}