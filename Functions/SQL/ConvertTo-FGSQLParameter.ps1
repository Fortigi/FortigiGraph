function ConvertTo-FGSQLParameter {
    <#
    .SYNOPSIS
    Converts a Graph API value to a SQL parameter value with proper type handling.

    .DESCRIPTION
    Handles type conversion from Graph API JSON values to SQL types, including:
    - GUIDs
    - Booleans
    - DateTimes
    - Arrays (converted to comma-separated strings)
    - NULL values
    - Strings

    .PARAMETER Value
    The value from Graph API to convert

    .PARAMETER AttributeName
    Name of the attribute (used for type detection)

    .PARAMETER SqlCommand
    The SqlCommand object to add the parameter to

    .EXAMPLE
    ConvertTo-FGSQLParameter -Value $user.id -AttributeName 'id' -SqlCommand $cmd

    .NOTES
    Adds the parameter directly to the provided SqlCommand object
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$AttributeName,

        [Parameter(Mandatory = $true)]
        [System.Data.SqlClient.SqlCommand]$SqlCommand
    )

    # Handle NULL values
    if ($null -eq $Value -or $Value -eq '') {
        $SqlCommand.Parameters.AddWithValue("@$AttributeName", [DBNull]::Value) | Out-Null
        return
    }

    # Handle GUIDs (id, ownerId, managerId, etc.)
    if ($AttributeName -eq 'id' -or $AttributeName -like '*Id') {
        try {
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", [Guid]$Value) | Out-Null
        }
        catch {
            # If GUID conversion fails, treat as string
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", $Value.ToString()) | Out-Null
        }
        return
    }

    # Handle Booleans (accountEnabled, mailEnabled, securityEnabled, etc.)
    if ($AttributeName -like '*Enabled' -or $AttributeName -like '*Synced' -or $AttributeName -like 'isAssignable*') {
        $SqlCommand.Parameters.AddWithValue("@$AttributeName", [bool]$Value) | Out-Null
        return
    }

    # Handle DateTimes
    if ($AttributeName -like '*DateTime' -or $AttributeName -like '*Date') {
        try {
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", [DateTime]$Value) | Out-Null
        }
        catch {
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", [DBNull]::Value) | Out-Null
        }
        return
    }

    # Handle Arrays (convert to comma-separated string)
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", [DBNull]::Value) | Out-Null
        }
        else {
            $SqlCommand.Parameters.AddWithValue("@$AttributeName", ($Value -join ', ')) | Out-Null
        }
        return
    }

    # Default: Convert to string
    $SqlCommand.Parameters.AddWithValue("@$AttributeName", $Value.ToString()) | Out-Null
}
