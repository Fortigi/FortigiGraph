# Secure Configuration Helper for FortigiGraph Tests
# Encrypts and decrypts sensitive credentials using Windows Data Protection API (DPAPI)
# Credentials can only be decrypted by the same user on the same machine

function Get-SecureConfigValue {
    <#
    .SYNOPSIS
    Gets a configuration value, prompting for it if not set, and encrypting it for future use.

    .DESCRIPTION
    This function checks if a secure credential exists in the config file. If not, it prompts
    the user for the credential, encrypts it using DPAPI, and stores it in the config file.
    On subsequent runs, it decrypts and returns the stored credential.

    .PARAMETER ConfigPath
    Path to the configuration JSON file

    .PARAMETER PropertyPath
    Dot-notation path to the property (e.g., "Azure.AdminUserPassword" or "Graph.ClientSecret")

    .PARAMETER PromptMessage
    Message to display when prompting for the credential

    .PARAMETER AsSecureString
    If specified, returns a SecureString instead of plain text

    .PARAMETER AllowEmpty
    If specified, allows empty/blank values (useful for optional secrets like ClientSecret)

    .EXAMPLE
    $password = Get-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword" -PromptMessage "SQL Admin Password" -AsSecureString

    .EXAMPLE
    $secret = Get-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Graph.ClientSecret" -PromptMessage "Graph Client Secret (leave empty for interactive auth)" -AllowEmpty
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$PropertyPath,

        [Parameter(Mandatory = $true)]
        [string]$PromptMessage,

        [switch]$AsSecureString,

        [switch]$AllowEmpty
    )

    # Load config
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # Parse property path (e.g., "Azure.AdminUserPassword" -> Azure object, AdminUserPassword property)
    $pathParts = $PropertyPath -split '\.'
    $securePropertyName = $pathParts[-1] + "_Encrypted"

    # Navigate to the parent object
    $parentObj = $config
    for ($i = 0; $i -lt $pathParts.Length - 1; $i++) {
        $parentObj = $parentObj.($pathParts[$i])
    }

    $propertyName = $pathParts[-1]
    $currentValue = $parentObj.$propertyName
    $encryptedValue = $parentObj.$securePropertyName

    # Check if we have an encrypted value
    if ($encryptedValue) {
        try {
            # Decrypt and return
            $secureString = ConvertTo-SecureString -String $encryptedValue
            if ($AsSecureString) {
                return $secureString
            } else {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
                return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            }
        } catch {
            Write-Host "  ⚠ Failed to decrypt stored credential. You may need to re-enter it." -ForegroundColor Yellow
        }
    }

    # Check if we have a plaintext value that needs to be migrated
    if ($currentValue -and $currentValue -ne "" -and $currentValue -notlike "YOUR-*" -and $currentValue -notlike "YourStrong*") {
        Write-Host "  → Migrating plaintext credential to encrypted storage..." -ForegroundColor Cyan

        # Encrypt the existing value
        $secureString = ConvertTo-SecureString -String $currentValue -AsPlainText -Force
        $encrypted = ConvertFrom-SecureString -SecureString $secureString

        # Update config
        $parentObj | Add-Member -NotePropertyName $securePropertyName -NotePropertyValue $encrypted -Force
        $parentObj.$propertyName = ""  # Clear plaintext

        # Save config
        $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath

        Write-Host "  ✓ Credential encrypted and stored securely" -ForegroundColor Green

        if ($AsSecureString) {
            return $secureString
        } else {
            return $currentValue
        }
    }

    # No credential found, prompt user
    Write-Host "`n  → $PromptMessage" -ForegroundColor Yellow

    if ($AllowEmpty) {
        Write-Host "    (Press Enter to leave empty)" -ForegroundColor Gray
    }

    $credential = Read-Host -AsSecureString

    # Check if empty
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential)
    $plainValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    if ([string]::IsNullOrWhiteSpace($plainValue)) {
        if ($AllowEmpty) {
            Write-Host "  → Using empty value (interactive auth will be used)" -ForegroundColor Cyan
            return $null
        } else {
            Write-Host "  ✗ This credential cannot be empty" -ForegroundColor Red
            throw "Required credential was not provided: $PropertyPath"
        }
    }

    # Encrypt and store
    $encrypted = ConvertFrom-SecureString -SecureString $credential
    $parentObj | Add-Member -NotePropertyName $securePropertyName -NotePropertyValue $encrypted -Force
    $parentObj.$propertyName = ""  # Clear any plaintext value

    # Save config
    $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath

    Write-Host "  ✓ Credential encrypted and stored securely" -ForegroundColor Green

    if ($AsSecureString) {
        return $credential
    } else {
        return $plainValue
    }
}

function Clear-SecureConfigValue {
    <#
    .SYNOPSIS
    Clears a stored encrypted credential from the config file.

    .DESCRIPTION
    Removes both the plaintext and encrypted versions of a credential from the config file.
    Useful for forcing re-entry of credentials or when credentials have changed.

    .PARAMETER ConfigPath
    Path to the configuration JSON file

    .PARAMETER PropertyPath
    Dot-notation path to the property to clear

    .EXAMPLE
    Clear-SecureConfigValue -ConfigPath $ConfigFile -PropertyPath "Azure.AdminUserPassword"
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$PropertyPath
    )

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # Parse property path
    $pathParts = $PropertyPath -split '\.'
    $securePropertyName = $pathParts[-1] + "_Encrypted"

    # Navigate to parent object
    $parentObj = $config
    for ($i = 0; $i -lt $pathParts.Length - 1; $i++) {
        $parentObj = $parentObj.($pathParts[$i])
    }

    $propertyName = $pathParts[-1]

    # Clear both values
    $parentObj.$propertyName = ""
    if ($parentObj.PSObject.Properties.Name -contains $securePropertyName) {
        $parentObj.PSObject.Properties.Remove($securePropertyName)
    }

    # Save config
    $config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath

    Write-Host "  ✓ Cleared stored credential: $PropertyPath" -ForegroundColor Green
}

function Test-SecureConfigAvailable {
    <#
    .SYNOPSIS
    Tests if a secure credential is available (either encrypted or plaintext).

    .PARAMETER ConfigPath
    Path to the configuration JSON file

    .PARAMETER PropertyPath
    Dot-notation path to the property to check

    .RETURNS
    $true if credential is available, $false otherwise
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$PropertyPath
    )

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

    # Parse property path
    $pathParts = $PropertyPath -split '\.'
    $securePropertyName = $pathParts[-1] + "_Encrypted"

    # Navigate to parent object
    $parentObj = $config
    for ($i = 0; $i -lt $pathParts.Length - 1; $i++) {
        $parentObj = $parentObj.($pathParts[$i])
    }

    $propertyName = $pathParts[-1]
    $currentValue = $parentObj.$propertyName
    $encryptedValue = $parentObj.$securePropertyName

    # Check if we have either encrypted or valid plaintext
    if ($encryptedValue) {
        return $true
    }

    if ($currentValue -and $currentValue -ne "" -and $currentValue -notlike "YOUR-*" -and $currentValue -notlike "YourStrong*") {
        return $true
    }

    return $false
}
