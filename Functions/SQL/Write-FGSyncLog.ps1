function Write-FGSyncLog {
    <#
    .SYNOPSIS
    Writes a sync log entry to the GraphSyncLog table.

    .DESCRIPTION
    Records sync operation details including start time, end time, duration,
    record count, status, and any error messages. Creates the GraphSyncLog
    table if it doesn't exist.

    This function is called automatically by all Sync-FG* functions to provide
    a central log of sync operations for monitoring and troubleshooting.

    .PARAMETER SyncType
    The type of sync operation (e.g., "Users", "Groups", "GroupMembers").

    .PARAMETER StartTime
    When the sync operation started.

    .PARAMETER EndTime
    When the sync operation completed. If not provided, uses current time.

    .PARAMETER RecordCount
    Number of records synced.

    .PARAMETER Status
    Status of the sync operation: "Success", "Failed", or "PartialSuccess".

    .PARAMETER ErrorMessage
    Error message if the sync failed or partially succeeded.

    .PARAMETER TableName
    The target table name that was synced to.

    .EXAMPLE
    Write-FGSyncLog -SyncType "Users" -StartTime $startTime -RecordCount 1500 -Status "Success" -TableName "GraphUsers"

    Logs a successful user sync operation.

    .EXAMPLE
    Write-FGSyncLog -SyncType "GroupMembers" -StartTime $startTime -RecordCount 0 -Status "Failed" -ErrorMessage "Connection timeout" -TableName "GraphGroupMembers"

    Logs a failed group members sync operation with error details.

    .NOTES
    Requires an active SQL connection via Connect-FGSQLServer.
    The GraphSyncLog table is NOT a temporal table (no history tracking needed).
    #>

    [CmdletBinding()]
    [Alias("Write-SyncLog")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$SyncType,

        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,

        [Parameter(Mandatory = $false)]
        [datetime]$EndTime = (Get-Date),

        [Parameter(Mandatory = $false)]
        [int]$RecordCount = 0,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Success", "Failed", "PartialSuccess")]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = $null,

        [Parameter(Mandatory = $false)]
        [string]$TableName = $null
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        Write-Warning "Cannot write sync log: Not connected to SQL Server."
        return
    }

    # Calculate duration
    $durationSeconds = [int]($EndTime - $StartTime).TotalSeconds

    # Prepare log entry data to pass to scriptblock
    $logEntry = @{
        SyncType = $SyncType
        StartTime = $StartTime
        EndTime = $EndTime
        DurationSeconds = $durationSeconds
        RecordCount = $RecordCount
        Status = $Status
        ErrorMessage = $ErrorMessage
        TableName = $TableName
    }

    try {
        $connection = $null
        try {
            # Create and open connection
            $connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
            $connection.Open()

            # Check if GraphSyncLog table exists, create if not
            $checkTableQuery = @"
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'GraphSyncLog')
BEGIN
    CREATE TABLE dbo.GraphSyncLog (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        SyncType NVARCHAR(100) NOT NULL,
        StartTime DATETIME2 NOT NULL,
        EndTime DATETIME2 NOT NULL,
        DurationSeconds INT NOT NULL,
        RecordCount INT NOT NULL,
        Status NVARCHAR(50) NOT NULL,
        ErrorMessage NVARCHAR(MAX) NULL,
        TableName NVARCHAR(255) NULL,
        CreatedAt DATETIME2 DEFAULT GETUTCDATE()
    );

    -- Create index for querying by SyncType and time
    CREATE NONCLUSTERED INDEX IX_GraphSyncLog_SyncType_StartTime
    ON dbo.GraphSyncLog (SyncType, StartTime DESC);

    -- Create index for querying latest sync per type
    CREATE NONCLUSTERED INDEX IX_GraphSyncLog_StartTime
    ON dbo.GraphSyncLog (StartTime DESC);
END
"@
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = $checkTableQuery
            $cmd.ExecuteNonQuery() | Out-Null

            # Insert log entry
            $insertQuery = @"
INSERT INTO dbo.GraphSyncLog (SyncType, StartTime, EndTime, DurationSeconds, RecordCount, Status, ErrorMessage, TableName)
VALUES (@SyncType, @StartTime, @EndTime, @DurationSeconds, @RecordCount, @Status, @ErrorMessage, @TableName)
"@
            $insertCmd = $connection.CreateCommand()
            $insertCmd.CommandText = $insertQuery
            $insertCmd.Parameters.AddWithValue("@SyncType", $logEntry.SyncType) | Out-Null
            $insertCmd.Parameters.AddWithValue("@StartTime", $logEntry.StartTime) | Out-Null
            $insertCmd.Parameters.AddWithValue("@EndTime", $logEntry.EndTime) | Out-Null
            $insertCmd.Parameters.AddWithValue("@DurationSeconds", $logEntry.DurationSeconds) | Out-Null
            $insertCmd.Parameters.AddWithValue("@RecordCount", $logEntry.RecordCount) | Out-Null
            $insertCmd.Parameters.AddWithValue("@Status", $logEntry.Status) | Out-Null

            if ($logEntry.ErrorMessage) {
                $insertCmd.Parameters.AddWithValue("@ErrorMessage", $logEntry.ErrorMessage) | Out-Null
            }
            else {
                $insertCmd.Parameters.AddWithValue("@ErrorMessage", [DBNull]::Value) | Out-Null
            }

            if ($logEntry.TableName) {
                $insertCmd.Parameters.AddWithValue("@TableName", $logEntry.TableName) | Out-Null
            }
            else {
                $insertCmd.Parameters.AddWithValue("@TableName", [DBNull]::Value) | Out-Null
            }

            $insertCmd.ExecuteNonQuery() | Out-Null
        }
        finally {
            # Always clean up connection
            if ($connection -and $connection.State -eq 'Open') {
                $connection.Close()
            }
            if ($connection) {
                $connection.Dispose()
            }
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Sync log written: $SyncType - $Status ($durationSeconds seconds, $RecordCount records)" -ForegroundColor Gray
    }
    catch {
        Write-Warning "Failed to write sync log: $_"
        # Don't throw - logging failure shouldn't fail the sync
    }
}
