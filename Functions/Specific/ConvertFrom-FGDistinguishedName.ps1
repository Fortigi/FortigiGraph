function ConvertFrom-FGDistinguishedName {
    <#
    .SYNOPSIS
    Extracts the organizational unit (OU) path from an Active Directory distinguished name (DN).

    .DESCRIPTION
    Parses a distinguished name string (e.g., "CN=_AM_SUP,OU=Distribution,OU=Groups,OU=Clients,DC=domain,DC=com")
    and returns the OU path in a human-readable, reversed format (e.g., "Clients/Groups/Distribution").

    The function:
    - Splits the DN on commas (respecting escaped commas)
    - Extracts only the OU= components
    - Reverses their order (DN is leaf-to-root, output is root-to-leaf)
    - Joins them with a forward slash separator

    .PARAMETER DistinguishedName
    The Active Directory distinguished name string to parse.

    .EXAMPLE
    ConvertFrom-FGDistinguishedName -DistinguishedName "CN=_AM_SUP,OU=Distribution,OU=Groups,OU=Clients,DC=fujitsu,DC=ad,DC=portofrotterdam,DC=com"

    Returns: "Clients/Groups/Distribution"

    .EXAMPLE
    ConvertFrom-FGDistinguishedName -DistinguishedName "CN=User,OU=Users,DC=domain,DC=com"

    Returns: "Users"

    .NOTES
    Returns $null if the input is empty or contains no OU= components.
    #>

    [CmdletBinding()]
    [Alias("ConvertFrom-DistinguishedName")]
    Param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [string]$DistinguishedName
    )

    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return $null
    }

    # Split on commas that are not escaped with a backslash
    $parts = $DistinguishedName -split '(?<!\\),'

    # Extract only the OU components and strip the OU= prefix
    $ouParts = @($parts | Where-Object { $_ -match '^OU=' } | ForEach-Object { $_ -replace '^OU=', '' })

    if ($ouParts.Count -eq 0) {
        return $null
    }

    # Reverse to get root-to-leaf order and join with slash
    [array]::Reverse($ouParts)
    return ($ouParts -join '/')
}
