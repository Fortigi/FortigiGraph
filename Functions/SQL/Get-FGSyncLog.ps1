function Get-FGSyncLog {
    <#
    .SYNOPSIS
    Retrieves sync log entries from the GraphSyncLog table.

    .DESCRIPTION
    Shows recent sync operations with their status, duration, and record counts.
    Can filter by sync type, status, or number of entries. Useful for monitoring
    sync health and troubleshooting failures.

    .PARAMETER ConfigFile
    Path to a JSON config file containing SQL connection details.
    If not provided, uses the existing SQL connection ($global:FGSQLConnectionString).

    .PARAMETER SyncType
    Filter to show only specific sync types (e.g., "Users", "Groups", "GroupMembers").

    .PARAMETER Status
    Filter by status: "Success", "Failed", or "PartialSuccess".

    .PARAMETER Last
    Number of recent entries to show. Default: 20.

    .PARAMETER Summary
    If specified, shows a summary view with only the latest sync per type.

    .EXAMPLE
    Get-FGSyncLog

    Shows the last 20 sync log entries using the current SQL connection.

    .EXAMPLE
    Get-FGSyncLog -ConfigFile ".\config.json" -Last 50

    Connects using config file and shows the last 50 sync entries.

    .EXAMPLE
    Get-FGSyncLog -SyncType "Users" -Last 10

    Shows the last 10 user sync operations.

    .EXAMPLE
    Get-FGSyncLog -Status "Failed"

    Shows all failed sync operations (last 20).

    .EXAMPLE
    Get-FGSyncLog -Summary

    Shows only the most recent sync for each sync type.

    .EXAMPLE
    $logs = Get-FGSyncLog -PassThru

    Returns log objects for pipeline processing instead of displaying a table.

    .NOTES
    Requires either:
    - An active SQL connection via Connect-FGSQLServer, or
    - A ConfigFile with SQL connection details
    #>

    [CmdletBinding()]
    [Alias("Get-SyncLog")]
    Param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Users", "Groups", "GroupMembers", "GroupEligibleMembers", "GroupOwners",
                     "Catalogs", "AccessPackages", "AccessPackageAssignments",
                     "AccessPackageResourceRoleScopes", "AccessPackageAssignmentPolicies",
                     "AccessPackageAssignmentRequests", "AccessPackageAccessReviews")]
        [string]$SyncType,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Success", "Failed", "PartialSuccess")]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [int]$Last = 20,

        [Parameter(Mandatory = $false)]
        [switch]$Summary,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Handle connection
    $needsDisconnect = $false

    if ($ConfigFile) {
        # Connect using config file
        if (-not (Test-Path $ConfigFile)) {
            throw "Config file not found: $ConfigFile"
        }

        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

        # Check if already connected to the same server
        $targetServer = $config.Azure.SQLServerName
        if ($global:FGSQLServerName -ne $targetServer) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Connecting to SQL Server..." -ForegroundColor Gray
            Connect-FGSQLServer -ConfigFile $ConfigFile -SkipFirewallUpdate | Out-Null
            $needsDisconnect = $true
        }
    }
    elseif (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first or provide -ConfigFile."
    }

    try {
        # Check if GraphSyncLog table exists
        $tableExists = Invoke-FGSQLQuery -Query "SELECT COUNT(*) FROM sys.tables WHERE name = 'GraphSyncLog'" -AsScalar

        if ($tableExists -eq 0) {
            Write-Warning "GraphSyncLog table does not exist. Run a sync operation first to create it."
            return
        }

        # Build query
        if ($Summary) {
            # Summary query - latest sync per type
            $query = @"
WITH LatestSync AS (
    SELECT SyncType, MAX(Id) as MaxId
    FROM dbo.GraphSyncLog
    GROUP BY SyncType
)
SELECT
    l.SyncType,
    l.StartTime,
    l.EndTime,
    l.DurationSeconds,
    l.RecordCount,
    l.Status,
    l.ErrorMessage,
    l.TableName
FROM dbo.GraphSyncLog l
INNER JOIN LatestSync ls ON l.Id = ls.MaxId
ORDER BY l.SyncType
"@
        }
        else {
            # Regular query with parameterized filters
            $whereClauses = @()
            $queryParams = @{}

            if ($SyncType) {
                $whereClauses += "SyncType = @SyncType"
                $queryParams['@SyncType'] = $SyncType
            }

            if ($Status) {
                $whereClauses += "Status = @Status"
                $queryParams['@Status'] = $Status
            }

            $whereClause = if ($whereClauses.Count -gt 0) { "WHERE " + ($whereClauses -join " AND ") } else { "" }

            $query = @"
SELECT TOP (@Last)
    SyncType,
    StartTime,
    EndTime,
    DurationSeconds,
    RecordCount,
    Status,
    ErrorMessage,
    TableName
FROM dbo.GraphSyncLog
$whereClause
ORDER BY StartTime DESC
"@
            $queryParams['@Last'] = $Last
        }

        # Execute query with parameterized values
        $results = Invoke-FGSQLCommand -ScriptBlock {
            param($connection)
            $cmd = $connection.CreateCommand()
            $cmd.CommandText = $using:query
            $params = $using:queryParams
            foreach ($key in $params.Keys) {
                $cmd.Parameters.AddWithValue($key, $params[$key]) | Out-Null
            }
            $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
            $dataTable = New-Object System.Data.DataTable
            $adapter.Fill($dataTable) | Out-Null
            return $dataTable
        }

        if (-not $results -or $results.Count -eq 0) {
            Write-Host "No sync log entries found." -ForegroundColor Yellow
            return
        }

        # Format output
        if ($Summary) {
            Write-Host "`n=== Sync Status Summary ===" -ForegroundColor Cyan
            Write-Host ""
        }
        else {
            $title = "Last $Last Sync Operations"
            if ($SyncType) { $title += " (Type: $SyncType)" }
            if ($Status) { $title += " (Status: $Status)" }
            Write-Host "`n=== $title ===" -ForegroundColor Cyan
            Write-Host ""
        }

        # Display results in a formatted table
        $formattedResults = $results | ForEach-Object {
            $statusColor = switch ($_.Status) {
                "Success" { "Green" }
                "Failed" { "Red" }
                "PartialSuccess" { "Yellow" }
                default { "White" }
            }

            # Format duration
            $duration = if ($_.DurationSeconds -lt 60) {
                "$($_.DurationSeconds)s"
            }
            elseif ($_.DurationSeconds -lt 3600) {
                "$([math]::Floor($_.DurationSeconds / 60))m $($_.DurationSeconds % 60)s"
            }
            else {
                "$([math]::Floor($_.DurationSeconds / 3600))h $([math]::Floor(($_.DurationSeconds % 3600) / 60))m"
            }

            # Format time ago
            $timeAgo = ""
            if ($_.StartTime) {
                $elapsed = (Get-Date) - [datetime]$_.StartTime
                if ($elapsed.TotalMinutes -lt 60) {
                    $timeAgo = "$([math]::Round($elapsed.TotalMinutes))m ago"
                }
                elseif ($elapsed.TotalHours -lt 24) {
                    $timeAgo = "$([math]::Round($elapsed.TotalHours, 1))h ago"
                }
                else {
                    $timeAgo = "$([math]::Round($elapsed.TotalDays, 1))d ago"
                }
            }

            [PSCustomObject]@{
                SyncType = $_.SyncType
                StartTime = if ($_.StartTime) { ([datetime]$_.StartTime).ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                TimeAgo = $timeAgo
                Duration = $duration
                Records = $_.RecordCount
                Status = $_.Status
                Error = if ($_.ErrorMessage) {
                    if ($_.ErrorMessage.Length -gt 50) {
                        $_.ErrorMessage.Substring(0, 47) + "..."
                    } else {
                        $_.ErrorMessage
                    }
                } else { "" }
            }
        }

        # Output based on PassThru switch
        if ($PassThru) {
            return $formattedResults
        }
        else {
            # Output as table
            $formattedResults | Format-Table -AutoSize -Property SyncType, StartTime, TimeAgo, Duration, Records, Status, Error | Out-Host

            # If showing summary, also show any failures
            if ($Summary) {
                $failures = $results | Where-Object { $_.Status -eq "Failed" }
                if ($failures) {
                    Write-Host "Warning: $($failures.Count) sync type(s) in failed state!" -ForegroundColor Red
                }

                $partialSuccess = $results | Where-Object { $_.Status -eq "PartialSuccess" }
                if ($partialSuccess) {
                    Write-Host "Note: $($partialSuccess.Count) sync type(s) with partial success (some errors occurred)" -ForegroundColor Yellow
                }
            }
        }
    }
    finally {
        # Note: We don't disconnect here as the user might want to run more queries
        # If they provided a config file and weren't already connected, they can disconnect manually
    }
}
