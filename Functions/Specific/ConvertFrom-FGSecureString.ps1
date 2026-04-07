function ConvertFrom-FGSecureString {
    [alias("ConvertFrom-SecureStringToPlainText")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [object]$SecureString
    )

    if ($SecureString -is [string]) {
        $SecureString = ConvertTo-SecureString -String $SecureString
    }
    elseif ($SecureString -isnot [System.Security.SecureString]) {
        throw "SecureString must be a [SecureString] or an encrypted [string]."
    }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}
