function New-FGDataTableFromGraphObjects {
    <#
    .SYNOPSIS
    Creates a DataTable from Graph API objects for use with SQL bulk operations.

    .DESCRIPTION
    Shared helper used by Sync-FG* functions to build a System.Data.DataTable from
    an array of Graph API objects. Handles:
    - Column creation with correct .NET types based on SQL type mapping
    - Value extraction and type conversion for each attribute
    - DBNull handling for null/empty values
    - Array-to-string conversion (e.g., groupTypes, proxyAddresses)
    - Custom value resolvers for special attributes (e.g., managerId, lastSignInDateTime)

    .PARAMETER GraphObjects
    Array of objects returned from Microsoft Graph API.

    .PARAMETER Columns
    Hashtable mapping column names to SQL types.

    .PARAMETER Attributes
    Array of attribute names to extract from each Graph object.

    .PARAMETER ValueResolvers
    Optional hashtable mapping attribute names to scriptblocks that extract the value
    from a Graph object. Used for special attributes that don't map directly.
    The scriptblock receives the Graph object as $args[0].

    .EXAMPLE
    $dt = New-FGDataTableFromGraphObjects -GraphObjects $allUsers -Columns $columns -Attributes $Attributes

    .EXAMPLE
    $resolvers = @{
        'managerId' = { param($obj) if ($obj.manager -and $obj.manager.id) { [guid]$obj.manager.id } else { $null } }
    }
    $dt = New-FGDataTableFromGraphObjects -GraphObjects $allUsers -Columns $columns -Attributes $Attributes -ValueResolvers $resolvers
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [array]$GraphObjects,

        [Parameter(Mandatory = $true)]
        [hashtable]$Columns,

        [Parameter(Mandatory = $true)]
        [string[]]$Attributes,

        [Parameter(Mandatory = $false)]
        [hashtable]$ValueResolvers = @{}
    )

    $dataTable = New-Object System.Data.DataTable

    # Add columns based on attributes and their SQL types
    foreach ($attr in $Attributes) {
        $sqlType = $Columns[$attr]
        $dotNetType = switch -Regex ($sqlType) {
            'UNIQUEIDENTIFIER' { [guid] }
            'BIT' { [bool] }
            'DATETIME2' { [datetime] }
            'INT' { [int] }
            'BIGINT' { [long] }
            default { [string] }
        }
        $dataTable.Columns.Add($attr, $dotNetType) | Out-Null
    }

    # Populate DataTable with data
    foreach ($obj in $GraphObjects) {
        $row = $dataTable.NewRow()

        foreach ($attr in $Attributes) {
            $value = $null

            # Use custom resolver if provided, otherwise get value directly
            if ($ValueResolvers.ContainsKey($attr)) {
                $value = & $ValueResolvers[$attr] $obj
            }
            else {
                $value = $obj.$attr
            }

            # Convert value to appropriate type or DBNull
            if ($null -eq $value -or $value -eq '') {
                $row[$attr] = [DBNull]::Value
            }
            else {
                $sqlType = $Columns[$attr]
                try {
                    switch -Regex ($sqlType) {
                        'UNIQUEIDENTIFIER' { $row[$attr] = [guid]$value }
                        'BIT' { $row[$attr] = [bool]$value }
                        'DATETIME2' { $row[$attr] = [datetime]$value }
                        'INT' { $row[$attr] = [int]$value }
                        'BIGINT' { $row[$attr] = [long]$value }
                        default {
                            # For arrays like groupTypes, join them
                            if ($value -is [Array]) {
                                $row[$attr] = [string]($value -join ',')
                            }
                            else {
                                $row[$attr] = [string]$value
                            }
                        }
                    }
                }
                catch {
                    # If conversion fails, use DBNull
                    $row[$attr] = [DBNull]::Value
                }
            }
        }

        $dataTable.Rows.Add($row)
    }

    return ,$dataTable
}
