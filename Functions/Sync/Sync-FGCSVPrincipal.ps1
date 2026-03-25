function Sync-FGCSVPrincipal {
    <#
    .SYNOPSIS
    Syncs principals from a CSV file (Users.csv) into the Principals table.

    .DESCRIPTION
    Reads a semicolon-delimited CSV file containing user/employee records and syncs them
    to the Principals table in the universal resource model. Each employee is mapped to a
    Principal with a deterministic GUID based on their EmployeeNumber.

    The function:
    - Reads the CSV with semicolon delimiter and UTF8 encoding
    - Generates deterministic GUIDs from EmployeeNumber for stable identity
    - Looks up the HR system ID from $Global:FGCSVSystemLookup
    - Maps CSV columns to Principals schema with principalType='Employee'
    - Builds a global lookup ($Global:FGCSVPrincipalLookup) for downstream syncs
    - Uses bulk merge with scoped delete
    - Logs sync status via Write-FGSyncLog

    .PARAMETER Path
    Path to the Users.csv file.

    .PARAMETER RecreateTable
    If specified, drops and recreates the Principals table (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGCSVPrincipal -Path "C:\Data\Users.csv"

    .EXAMPLE
    Sync-FGCSVPrincipal -Path "C:\Data\Users.csv" -RecreateTable

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVSystemLookup to contain system mappings (or at least one system record)
    - CSV must use semicolon delimiter and UTF8 encoding
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVPrincipal")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
    )

    $TableName = "Principals"

    # Helper: Generate deterministic GUID from a string
    function New-DeterministicGuid {
        param([string]$InputString)
        if ([string]::IsNullOrEmpty($InputString)) { throw "InputString must not be null or empty" }
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hash = $md5.ComputeHash($bytes)
        $md5.Dispose()
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        return [guid]"$($hex.Substring(0,8))-$($hex.Substring(8,4))-$($hex.Substring(12,4))-$($hex.Substring(16,4))-$($hex.Substring(20,12))"
    }

    # Track sync timing for logging
    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    # Validate CSV file exists
    if (-not (Test-Path -Path $Path)) {
        throw "CSV file not found: $Path"
    }

    try {

    # Resolve system ID for the HR system
    $systemId = $null
    if ($Global:FGCSVSystemLookup) {
        if ($Global:FGCSVSystemLookup.ContainsKey('HCM')) {
            $systemId = $Global:FGCSVSystemLookup['HCM']
        } else {
            # Use the first available system
            $systemId = $Global:FGCSVSystemLookup.Values | Select-Object -First 1
        }
    }

    if (-not $systemId) {
        throw "No system ID found. Please populate `$Global:FGCSVSystemLookup with system mappings."
    }

    $Global:FGCSVHRSystemId = $systemId
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using HR system ID: $systemId" -ForegroundColor Green

    # Ensure Principals table exists
    $principalColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'email'              = 'NVARCHAR(500)'
        'accountEnabled'     = 'BIT'
        'principalType'      = 'NVARCHAR(50)'
        'externalId'         = 'NVARCHAR(500)'
        'givenName'          = 'NVARCHAR(255)'
        'surname'            = 'NVARCHAR(255)'
        'department'         = 'NVARCHAR(255)'
        'jobTitle'           = 'NVARCHAR(255)'
        'companyName'        = 'NVARCHAR(255)'
        'employeeId'         = 'NVARCHAR(255)'
        'managerId'          = 'UNIQUEIDENTIFIER'
        'createdDateTime'    = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $principalColumns -PrimaryKey 'id' -RecreateTable:$RecreateTable
    if ($tableReady -eq $false) { return }

    # Read CSV
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Reading CSV file: $Path" -ForegroundColor Cyan
    $csvData = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8

    if (-not $csvData -or $csvData.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No records found in CSV file."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Total records read: $($csvData.Count)" -ForegroundColor Green

    # Build principal lookup for downstream syncs
    $Global:FGCSVPrincipalLookup = @{}

    # Build DataTable
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing principal data..." -ForegroundColor Cyan

    $principalAttributes = @('id', 'systemId', 'displayName', 'email', 'accountEnabled', 'principalType', 'externalId', 'department', 'jobTitle', 'employeeId', 'managerId', 'extendedAttributes')

    # Convert CSV rows to objects with resolved values
    $principalObjects = @()
    foreach ($row in $csvData) {
        if ([string]::IsNullOrWhiteSpace($row.EmployeeNumber)) {
            Write-Verbose "Skipping row with empty EmployeeNumber"
            continue
        }

        $principalId = New-DeterministicGuid -InputString "principal:$($row.EmployeeNumber)"

        # Store in global lookup for downstream syncs
        $Global:FGCSVPrincipalLookup[$row.EmployeeNumber] = $principalId

        # Also store by Employee_ID if different from EmployeeNumber
        if ($row.Employee_ID -and $row.Employee_ID -ne $row.EmployeeNumber) {
            $Global:FGCSVPrincipalLookup[$row.Employee_ID] = $principalId
        }

        # Build manager ID if manager corporate key is available
        $resolvedManagerId = $null
        if (-not [string]::IsNullOrWhiteSpace($row.Managers_CorperateKey)) {
            $resolvedManagerId = New-DeterministicGuid -InputString "principal:$($row.Managers_CorperateKey)"
        }

        # Build extended attributes
        $extended = @{}
        if ($row.Employee_Type) { $extended['Employee_Type'] = $row.Employee_Type }
        if ($row.OU_KEY) { $extended['OU_KEY'] = $row.OU_KEY }
        if ($row.Description) { $extended['Description'] = $row.Description }

        $extendedJson = $null
        if ($extended.Count -gt 0) {
            $extendedJson = $extended | ConvertTo-Json -Depth 10 -Compress
        }

        $principalObjects += [PSCustomObject]@{
            id                 = $principalId
            systemId           = $systemId
            displayName        = $row.Employee_fullname
            email              = $null
            accountEnabled     = $true
            principalType      = 'Employee'
            externalId         = $row.EmployeeNumber
            department         = $row.OU_KEY
            jobTitle           = $row.Job_Title
            employeeId         = $row.Employee_ID
            managerId          = $resolvedManagerId
            extendedAttributes = $extendedJson
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($principalObjects.Count) principals (lookup table: $($Global:FGCSVPrincipalLookup.Count) entries)" -ForegroundColor Green

    if ($principalObjects.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No valid principals to sync."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # Build DataTable using the shared helper
    $dataTable = New-FGDataTableFromGraphObjects -GraphObjects $principalObjects -Columns $principalColumns -Attributes $principalAttributes

    # Sync to SQL
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing principals to SQL Server..." -ForegroundColor Cyan

    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            # Bulk merge principals
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) principals..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName $TableName `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Principals: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Scoped delete: only delete principals for this systemId AND principalType='Employee'
            $deleteCmd = $connection.CreateCommand()
            $deleteCmd.Transaction = $transaction
            $deleteCmd.CommandText = @"
DELETE p FROM dbo.$TableName p
WHERE p.principalType = 'Employee'
  AND p.systemId = @systemId
  AND NOT EXISTS (
    SELECT 1 FROM #BulkMerge_$TableName bt
    WHERE bt.id = p.id
  )
"@
            $deleteCmd.Parameters.AddWithValue("@systemId", $systemId) | Out-Null
            $deletedCount = 0
            try {
                $deletedCount = $deleteCmd.ExecuteNonQuery()
            } catch {
                Write-Verbose "Scoped delete not available (temp table missing): $_"
            }
            $deleteCmd.Dispose()

            if ($deletedCount -gt 0) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale principals" -ForegroundColor Yellow
            }

            # Commit transaction
            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
                Deleted = $deletedCount
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    $syncRecordCount = $principalObjects.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Principal Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "System ID:         $systemId" -ForegroundColor White
    Write-Host "Total Principals:  $($principalObjects.Count)" -ForegroundColor White
    Write-Host "  Inserted:        $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:         $($syncResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:         $($syncResult.Deleted)" -ForegroundColor White
    Write-Host "Lookup entries:    $($Global:FGCSVPrincipalLookup.Count)" -ForegroundColor White
    Write-Host "`nAll changes tracked in $TableName temporal table" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        SystemId = $systemId
        TotalPrincipals = $principalObjects.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        Deleted = $syncResult.Deleted
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVPrincipals" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
