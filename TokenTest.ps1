Import-Module .\FortigiGraph.psm1 -Force

#https://github.com/secureworks/family-of-client-ids-research

#Ask use to login to teams
$ClientId = '1fec8e78-bce4-4aaf-ab1b-5451cc387264' #Microsoft Teams
Get-AccessTokenInteractive -TenantId 'Fortigi.onmicrosoft.com' -ClientId $ClientId
$Token = Get-AccessTokenDetail
Write-Host $Token
Write-Host $Token.scp

#Switch to Office
$ClientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c' #Office...
Get-AccessTokenWithRefreshToken -ClientID $ClientId -TenantId $Global:TenantId -RefreshToken $Global:RefreshToken
$Token = Get-AccessTokenDetail
Write-Host $Token
Write-Host $Token.scp

#Switch to Azure
$ClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46' #Azure CLI
$Resource = 'https://management.azure.com'
Get-AccessTokenWithRefreshToken -ClientId $ClientId -TenantId $global:TenantId -RefreshToken $Global:RefreshToken -Resource $Resource
$Token = Get-AccessTokenDetail
$Token
Write-Host $Token.scp

#Switch to AzAccount...
Connect-AzAccount -AccessToken $Global:AccessToken -AccountId 'wim@fortigi.nl'
Get-AzSubscription -TenantId $Global:TenantId
Get-AzResource

#Save you token... for 90 days
$TokenFile = "C:\Source\YouTokenName.token"
Save-Token -TokenFilePath 
Read-Token -TokenFile $TokenFile  