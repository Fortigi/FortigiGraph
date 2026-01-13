function Initialize-FGSQLTable {
    <#
    .SYNOPSIS
    Creates a temporal table in SQL Server for storing Microsoft Graph data with automatic versioning.

    .DESCRIPTION
    Creates a temporal table with the specified columns and automatically creates a history table
    for version tracking. All changes to the data are automatically tracked with timestamps.

    Tables created with this function support:
    - Automatic version history tracking
    - Point-in-time queries
    - Change detection between any two timestamps
    - No manual comparison required

    .PARAMETER TableName
    The name of the table to create (without dbo. prefix)

    .PARAMETER Columns
    A hashtable defining the columns. Key is column name, value is SQL data type.
    Do not include ValidFrom/ValidTo columns - these are added automatically.

    .PARAMETER PrimaryKey
    The column name(s) to use as primary key. Can be a single string or array of strings.

    .PARAMETER DropIfExists
    If specified, drops the table if it already exists before creating it.

    .EXAMPLE
    $columns = @{
        "UserPrincipalName" = "NVARCHAR(255)"
        "DisplayName" = "NVARCHAR(255)"
        "JobTitle" = "NVARCHAR(255)"
        "Department" = "NVARCHAR(255)"
        "AccountEnabled" = "BIT"
    }
    Initialize-FGSQLTable -TableName "GraphUsers" -Columns $columns -PrimaryKey "UserPrincipalName"

    Creates a temporal table for storing user data

    .EXAMPLE
    $columns = @{
        "GroupId" = "UNIQUEIDENTIFIER"
        "MemberUserPrincipalName" = "NVARCHAR(255)"
        "MemberType" = "NVARCHAR(50)"
    }
    Initialize-FGSQLTable -TableName "GraphGroupMembers" -Columns $columns -PrimaryKey @("GroupId", "MemberUserPrincipalName")

    Creates a temporal table for group membership with a composite primary key

    .NOTES
    Requires Connect-FGSQLServer to be called first to establish connection.
    The history table is automatically named as [TableName]History.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [System.String]$TableName,

        [Parameter(Mandatory = $true)]
        [Hashtable]$Columns,

        [Parameter(Mandatory = $true)]
        $PrimaryKey,

        [Parameter(Mandatory = $false)]
        [Switch]$DropIfExists
    )

    # Check if connected
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Build column definitions
    $columnDefs = @()
    foreach ($col in $Columns.GetEnumerator()) {
        $columnDefs += "    $($col.Key) $($col.Value)"
    }

    # Handle composite or single primary key
    if ($PrimaryKey -is [array]) {
        $pkColumns = $PrimaryKey -join ", "
    } else {
        $pkColumns = $PrimaryKey
    }

    try {
        $result = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)

            # Drop table if requested
            if ($DropIfExists) {
                Write-Verbose "Checking if table exists..."
                $dropCmd = $connection.CreateCommand()
                $dropCmd.CommandText = @"
IF EXISTS (SELECT * FROM sys.tables WHERE name = '$TableName')
BEGIN
    ALTER TABLE dbo.$TableName SET (SYSTEM_VERSIONING = OFF);
    DROP TABLE IF EXISTS dbo.${TableName}History;
    DROP TABLE IF EXISTS dbo.$TableName;
    PRINT 'Dropped existing table: $TableName';
END
"@
                $dropCmd.ExecuteNonQuery() | Out-Null
                Write-Host "Dropped existing table: $TableName" -ForegroundColor Yellow
            }

            # Build CREATE TABLE statement with temporal table configuration
            $createTableSQL = @"
CREATE TABLE dbo.$TableName (
$($columnDefs -join ",`n"),

    -- Temporal table system columns (auto-managed by SQL Server)
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    ValidTo DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo),

    -- Primary key
    CONSTRAINT PK_$TableName PRIMARY KEY ($pkColumns)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.${TableName}History));
"@

            Write-Verbose "Creating temporal table with SQL:`n$createTableSQL"

            $cmd = $connection.CreateCommand()
            $cmd.CommandText = $createTableSQL
            $cmd.ExecuteNonQuery() | Out-Null

            Write-Host "Successfully created temporal table: dbo.$TableName" -ForegroundColor Green
            Write-Host "  History table: dbo.${TableName}History" -ForegroundColor Green
            Write-Host "  Primary Key: $pkColumns" -ForegroundColor Green
            Write-Host "  Columns: $($Columns.Count)" -ForegroundColor Green

            # Create a helpful view for seeing all changes (drop first if exists)
            try {
                $dropViewCmd = $connection.CreateCommand()
                $dropViewCmd.CommandText = "IF EXISTS (SELECT * FROM sys.views WHERE name = 'vw_AllHistory_${TableName}') DROP VIEW dbo.vw_AllHistory_${TableName};"
                $dropViewCmd.ExecuteNonQuery() | Out-Null

                $viewSQL = @"
CREATE VIEW dbo.vw_AllHistory_${TableName} AS
SELECT
    *,
    CASE
        WHEN ValidTo = '9999-12-31 23:59:59.9999999' THEN 'Current'
        ELSE 'Historical'
    END AS RecordStatus
FROM dbo.$TableName FOR SYSTEM_TIME ALL;
"@

                $viewCmd = $connection.CreateCommand()
                $viewCmd.CommandText = $viewSQL
                $viewCmd.ExecuteNonQuery() | Out-Null
                Write-Host "  Created helper view: vw_AllHistory_${TableName}" -ForegroundColor Green
            } catch {
                Write-Warning "Could not create helper view (this is optional): $_"
            }

            return $true
        }

        return $result
    }
    catch {
        Write-Error "Failed to create temporal table: $_"
        return $false
    }
}
