function Save-Token {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        $TokenFilePath
    )

    if (!(Test-Path $TokenFilePath)) {
        Throw "TokenFilePath not found."
    }

    $TokenDetail = Get-AccessTokenDetail

    $TokenName = $Global:TenantId + "+" + $TokenDetail.idtyp + "+" + $TokenDetail.upn + ".token"

    $Token = @{
        "TenantId" =  $Global:TenantId
        "ClientId" =  $Global:ClientId
        "RefreshToken" =  $Global:RefreshToken
    }
    $File = New-Item -Path $TokenFilePath -Name $TokenName
    $Token | ConvertTo-Json | Out-File $File

}


