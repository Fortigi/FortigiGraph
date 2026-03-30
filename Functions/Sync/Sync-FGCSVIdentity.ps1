function Sync-FGCSVIdentity {
    <#
    .SYNOPSIS
    Syncs identities and machine principals from a CSV file (Identities.csv).

    .DESCRIPTION
    Reads a semicolon-delimited CSV file containing identity records and processes them
    in two streams based on IDENTITYTYPE_ENGLISH:

    - "Primary" records → Identities table + IdentityMembers table (employee identities)
    - "Machine" records → Principals table (machine/service accounts)

    The function:
    - Reads the CSV with semicolon delimiter and UTF8 encoding
    - Separates records by identity type
    - For employees: creates Identity records and links them to Principals via IdentityMembers
    - For machines: creates Principal records with principalType='Machine'
    - Uses $Global:FGCSVPrincipalLookup (populated by Sync-FGCSVPrincipal) to link identities to principals
    - Uses bulk merge for all three target tables
    - Logs sync status via Write-FGSyncLog

    .PARAMETER Path
    Path to the Identities.csv file.

    .PARAMETER EmploymentPath
    Optional path to Employment.csv. When provided, resolves identity-to-org-unit links
    by extracting OU_KEY from OUREF_VALUE and looking up the contextId via
    $Global:FGCSVOrgUnitLookup (populated by Sync-FGCSVOrgUnit).

    .PARAMETER RecreateTable
    If specified, drops and recreates the target tables (WARNING: loses all history!)

    .EXAMPLE
    Sync-FGCSVIdentity -Path "C:\Data\Identities.csv"

    .EXAMPLE
    Sync-FGCSVIdentity -Path "C:\Data\Identities.csv" -RecreateTable

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Sync-FGCSVPrincipal to have been run first (populates $Global:FGCSVPrincipalLookup)
    - $Global:FGCSVSystemLookup to contain system mappings
    - CSV must use semicolon delimiter and UTF8 encoding
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVIdentity")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string]$EmploymentPath,

        [Parameter(Mandatory = $false)]
        [switch]$RecreateTable
    )

    $TableName = "Identities"

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

    # Validate principal lookup exists
    if (-not $Global:FGCSVPrincipalLookup -or $Global:FGCSVPrincipalLookup.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] `$Global:FGCSVPrincipalLookup is empty. Run Sync-FGCSVPrincipal first to populate it. Identity-to-principal linking will be skipped."
    }

    try {

    # Resolve system ID
    $systemId = $null
    if ($Global:FGCSVSystemLookup) {
        if ($Global:FGCSVSystemLookup.ContainsKey('HCM')) {
            $systemId = $Global:FGCSVSystemLookup['HCM']
        } else {
            $systemId = $Global:FGCSVSystemLookup.Values | Select-Object -First 1
        }
    }

    if (-not $systemId) {
        throw "No system ID found. Please populate `$Global:FGCSVSystemLookup with system mappings."
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $systemId" -ForegroundColor Green

    # --- Table definitions ---

    # Identities table
    $identityColumns = @{
        'id'                    = 'UNIQUEIDENTIFIER'
        'displayName'           = 'NVARCHAR(500)'
        'email'                 = 'NVARCHAR(500)'
        'jobTitle'              = 'NVARCHAR(255)'
        'employeeId'            = 'NVARCHAR(255)'
        'givenName'             = 'NVARCHAR(255)'
        'surname'               = 'NVARCHAR(255)'
        'primaryPrincipalId'    = 'UNIQUEIDENTIFIER'
        'accountCount'          = 'INT'
        'correlationConfidence' = 'INT'
        'isHrAnchored'          = 'BIT'
        'contextId'             = 'UNIQUEIDENTIFIER'
        'extendedAttributes'    = 'NVARCHAR(MAX)'
    }

    # IdentityMembers table
    $identityMemberColumns = @{
        'identityId'       = 'UNIQUEIDENTIFIER'
        'principalId'      = 'UNIQUEIDENTIFIER'
        'displayName'      = 'NVARCHAR(500)'
        'accountType'      = 'NVARCHAR(50)'
        'isPrimary'        = 'BIT'
        'signalConfidence' = 'INT'
    }

    # Principals table (for machine identities)
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

    # Ensure tables exist
    $tableReady = Initialize-FGSyncTable -TableName $TableName -Columns $identityColumns -PrimaryKey 'id' -RecreateTable:$RecreateTable
    if ($tableReady -eq $false) { return }

    $memberTableReady = Initialize-FGSyncTable -TableName "IdentityMembers" -Columns $identityMemberColumns -CompositePrimaryKey @('identityId', 'principalId') -RecreateTable:$RecreateTable
    if ($memberTableReady -eq $false) { return }

    $principalTableReady = Initialize-FGSyncTable -TableName "Principals" -Columns $principalColumns -PrimaryKey 'id' -RecreateTable:$RecreateTable
    if ($principalTableReady -eq $false) { return }

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

    # Separate records by identity type
    $employeeRecords = @($csvData | Where-Object { $_.IDENTITYTYPE_ENGLISH -eq 'Primary' })
    $machineRecords = @($csvData | Where-Object { $_.IDENTITYTYPE_ENGLISH -eq 'Machine' })

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Employee identities (Primary): $($employeeRecords.Count)" -ForegroundColor Cyan
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Machine identities: $($machineRecords.Count)" -ForegroundColor Cyan

    # Build Employment lookup: _ID (numeric) -> contextId (GUID) via OU_KEY
    $employmentLookup = @{}
    if ($EmploymentPath -and (Test-Path $EmploymentPath)) {
        if (-not $Global:FGCSVOrgUnitLookup -or $Global:FGCSVOrgUnitLookup.Count -eq 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] Employment.csv provided but `$Global:FGCSVOrgUnitLookup is empty. Run Sync-FGCSVOrgUnit first. Skipping org unit resolution."
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loading Employment.csv for org unit resolution..." -ForegroundColor Cyan
            $employmentData = Import-Csv -Path $EmploymentPath -Delimiter ';' -Encoding UTF8
            foreach ($emp in $employmentData) {
                $ouKey = $null
                # Extract OU_KEY from OUREF_VALUE: "Finance Chicago [GBG_CHI.B.F]"
                if ($emp.OUREF_VALUE -match '\[([^\]]+)\]') {
                    $ouKey = $Matches[1]
                }
                if ($ouKey -and $Global:FGCSVOrgUnitLookup.ContainsKey($ouKey)) {
                    $identityRefId = $emp.IDENTITYREF_ID.Trim().Trim('"')
                    if ($identityRefId -ne '' -and -not $employmentLookup.ContainsKey($identityRefId)) {
                        $employmentLookup[$identityRefId] = $Global:FGCSVOrgUnitLookup[$ouKey]
                    }
                }
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Built Employment lookup: $($employmentLookup.Count) identity-to-orgunit mappings" -ForegroundColor Green
        }
    }

    # ========================================
    # Pass 1: Machine identities → Principals
    # ========================================
    $machinePrincipalObjects = @()
    $machineResult = @{ Inserted = 0; Updated = 0; Deleted = 0 }

    if ($machineRecords.Count -gt 0) {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing machine identities..." -ForegroundColor Cyan

        foreach ($row in $machineRecords) {
            if ([string]::IsNullOrWhiteSpace($row._UID)) {
                Write-Verbose "Skipping machine record with empty _UID"
                continue
            }

            # Build extended attributes
            $extended = @{}
            if ($row.IDENTITYCATEGORY_ENGLISH) { $extended['IDENTITYCATEGORY_ENGLISH'] = $row.IDENTITYCATEGORY_ENGLISH }
            if ($row.VALIDFROM) { $extended['VALIDFROM'] = $row.VALIDFROM }
            if ($row.VALIDTO) { $extended['VALIDTO'] = $row.VALIDTO }

            $extendedJson = $null
            if ($extended.Count -gt 0) {
                $extendedJson = $extended | ConvertTo-Json -Depth 10 -Compress
            }

            $machinePrincipalObjects += [PSCustomObject]@{
                id                 = [guid]$row._UID
                systemId           = $systemId
                displayName        = $row._DISPLAYNAME
                email              = $null
                accountEnabled     = ($row.IDENTITYSTATUS_ENGLISH -eq 'Active')
                principalType      = 'Machine'
                externalId         = $row.IDENTITYID
                givenName          = $null
                surname            = $null
                department         = $null
                jobTitle           = $null
                companyName        = $null
                employeeId         = $null
                managerId          = $null
                createdDateTime    = $null
                extendedAttributes = $extendedJson
            }
        }

        if ($machinePrincipalObjects.Count -gt 0) {
            $machinePrincipalAttributes = @('id', 'systemId', 'displayName', 'email', 'accountEnabled', 'principalType', 'externalId', 'extendedAttributes')
            $machineDt = New-FGDataTableFromGraphObjects -GraphObjects $machinePrincipalObjects -Columns $principalColumns -Attributes $machinePrincipalAttributes

            $machineResult = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $transaction = $connection.BeginTransaction()

                try {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($machineDt.Rows.Count) machine principals..." -ForegroundColor Cyan

                    $mergeResult = Invoke-FGSQLBulkMerge `
                        -Connection $connection `
                        -Transaction $transaction `
                        -TargetTableName "Principals" `
                        -DataTable $machineDt `
                        -KeyColumns @('id')

                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Machine principals: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

                    $transaction.Commit()
                    $transaction.Dispose()

                    return @{
                        Inserted = $mergeResult.Inserted
                        Updated = $mergeResult.Updated
                        Deleted = 0
                    }
                }
                catch {
                    Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during machine principal sync: $_"
                    if ($transaction) {
                        $transaction.Rollback()
                        $transaction.Dispose()
                    }
                    throw
                }
            }
        }
    }

    # ========================================
    # Pass 2: Employee identities → Identities
    # ========================================
    $identityObjects = @()
    $identityMemberObjects = @()
    $identityResult = @{ Inserted = 0; Updated = 0; Deleted = 0 }
    $memberResult = @{ Inserted = 0; Updated = 0; Deleted = 0 }
    $unmatchedCount = 0

    if ($employeeRecords.Count -gt 0) {
        Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Processing employee identities..." -ForegroundColor Cyan

        foreach ($row in $employeeRecords) {
            if ([string]::IsNullOrWhiteSpace($row._UID)) {
                Write-Verbose "Skipping identity record with empty _UID"
                continue
            }

            # Look up the linked principal via IDENTITYID (matches Users.EmployeeNumber)
            $linkedPrincipalId = $null
            if ($Global:FGCSVPrincipalLookup) {
                # Primary match: IDENTITYID (6-letter code) matches EmployeeNumber in principal lookup
                if ($row.IDENTITYID -and $Global:FGCSVPrincipalLookup.ContainsKey($row.IDENTITYID)) {
                    $linkedPrincipalId = $Global:FGCSVPrincipalLookup[$row.IDENTITYID]
                }
                # Fallback: EmployeeID (8-digit HR number)
                elseif ($row.EmployeeID -and $Global:FGCSVPrincipalLookup.ContainsKey($row.EmployeeID)) {
                    $linkedPrincipalId = $Global:FGCSVPrincipalLookup[$row.EmployeeID]
                }
                else {
                    $unmatchedCount++
                }
            }

            # Build extended attributes
            $extended = @{}
            if ($row.IDENTITYCATEGORY_ENGLISH) { $extended['IDENTITYCATEGORY_ENGLISH'] = $row.IDENTITYCATEGORY_ENGLISH }
            if ($row.IDENTITYSTATUS_ENGLISH) { $extended['IDENTITYSTATUS_ENGLISH'] = $row.IDENTITYSTATUS_ENGLISH }
            if ($row.VALIDFROM) { $extended['VALIDFROM'] = $row.VALIDFROM }
            if ($row.VALIDTO) { $extended['VALIDTO'] = $row.VALIDTO }
            if ($row.OUREF_ID) { $extended['OUREF_ID'] = $row.OUREF_ID }
            if ($row._ID) { $extended['_ID'] = $row._ID }
            if ($row.IDENTITYID) { $extended['IDENTITYID'] = $row.IDENTITYID }

            $extendedJson = $null
            if ($extended.Count -gt 0) {
                $extendedJson = $extended | ConvertTo-Json -Depth 10 -Compress
            }

            # Resolve contextId from Employment lookup
            $contextId = $null
            if ($employmentLookup.Count -gt 0 -and $row._ID) {
                $idKey = $row._ID.Trim().Trim('"')
                if ($employmentLookup.ContainsKey($idKey)) {
                    $contextId = $employmentLookup[$idKey]
                }
            }

            $identityObjects += [PSCustomObject]@{
                id                    = [guid]$row._UID
                displayName           = $row._DISPLAYNAME
                email                 = $row.EMAIL
                jobTitle              = $row.JOBTITLE
                employeeId            = $row.EmployeeID
                givenName             = $row.FIRSTNAME
                surname               = $row.LASTNAME
                primaryPrincipalId    = $linkedPrincipalId
                accountCount          = if ($linkedPrincipalId) { 1 } else { 0 }
                correlationConfidence = 100
                isHrAnchored          = $true
                contextId             = $contextId
                extendedAttributes    = $extendedJson
            }

            # Create IdentityMember linking identity to principal
            if ($linkedPrincipalId) {
                $identityMemberObjects += [PSCustomObject]@{
                    identityId       = [guid]$row._UID
                    principalId      = $linkedPrincipalId
                    displayName      = $row._DISPLAYNAME
                    accountType      = 'HRAccount'
                    isPrimary        = $true
                    signalConfidence = 100
                }
            }
        }

        if ($unmatchedCount -gt 0) {
            Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] $unmatchedCount identity records could not be matched to a principal (EmployeeID not found in lookup)"
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Prepared $($identityObjects.Count) identities, $($identityMemberObjects.Count) identity-principal links" -ForegroundColor Green

        # Sync Identities
        if ($identityObjects.Count -gt 0) {
            $identityAttributes = @('id', 'displayName', 'email', 'jobTitle', 'employeeId', 'givenName', 'surname', 'primaryPrincipalId', 'accountCount', 'correlationConfidence', 'isHrAnchored', 'contextId', 'extendedAttributes')
            $identityDt = New-FGDataTableFromGraphObjects -GraphObjects $identityObjects -Columns $identityColumns -Attributes $identityAttributes

            $identityResult = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $transaction = $connection.BeginTransaction()

                try {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($identityDt.Rows.Count) identities..." -ForegroundColor Cyan

                    $mergeResult = Invoke-FGSQLBulkMerge `
                        -Connection $connection `
                        -Transaction $transaction `
                        -TargetTableName $TableName `
                        -DataTable $identityDt `
                        -KeyColumns @('id')

                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identities: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

                    # Scoped delete: only delete HR-anchored identities not in this batch
                    $deleteCmd = $connection.CreateCommand()
                    $deleteCmd.Transaction = $transaction
                    $deleteCmd.CommandText = @"
DELETE i FROM dbo.$TableName i
WHERE i.isHrAnchored = 1
  AND NOT EXISTS (
    SELECT 1 FROM #BulkMerge_$TableName bt
    WHERE bt.id = i.id
  )
"@
                    $deletedCount = 0
                    try {
                        $deletedCount = $deleteCmd.ExecuteNonQuery()
                    } catch {
                        Write-Verbose "Scoped delete not available (temp table missing): $_"
                    }
                    $deleteCmd.Dispose()

                    if ($deletedCount -gt 0) {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale identities" -ForegroundColor Yellow
                    }

                    $transaction.Commit()
                    $transaction.Dispose()

                    return @{
                        Inserted = $mergeResult.Inserted
                        Updated = $mergeResult.Updated
                        Deleted = $deletedCount
                    }
                }
                catch {
                    Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during identity sync: $_"
                    if ($transaction) {
                        $transaction.Rollback()
                        $transaction.Dispose()
                    }
                    throw
                }
            }
        }

        # ========================================
        # Pass 3: IdentityMembers
        # ========================================
        if ($identityMemberObjects.Count -gt 0) {
            $identityMemberAttributes = @('identityId', 'principalId', 'displayName', 'accountType', 'isPrimary', 'signalConfidence')
            $memberDt = New-FGDataTableFromGraphObjects -GraphObjects $identityMemberObjects -Columns $identityMemberColumns -Attributes $identityMemberAttributes

            $memberResult = Invoke-FGSQLCommand -ScriptBlock {
                param($connection)

                $transaction = $connection.BeginTransaction()

                try {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($memberDt.Rows.Count) identity members..." -ForegroundColor Cyan

                    $mergeResult = Invoke-FGSQLBulkMerge `
                        -Connection $connection `
                        -Transaction $transaction `
                        -TargetTableName "IdentityMembers" `
                        -DataTable $memberDt `
                        -KeyColumns @('identityId', 'principalId')

                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Identity members: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

                    $transaction.Commit()
                    $transaction.Dispose()

                    return @{
                        Inserted = $mergeResult.Inserted
                        Updated = $mergeResult.Updated
                        Deleted = 0
                    }
                }
                catch {
                    Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during identity member sync: $_"
                    if ($transaction) {
                        $transaction.Rollback()
                        $transaction.Dispose()
                    }
                    throw
                }
            }
        }
    }

    $syncRecordCount = $csvData.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Identity Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Total CSV records:       $($csvData.Count)" -ForegroundColor White
    Write-Host "Machine Principals:      $($machinePrincipalObjects.Count)" -ForegroundColor White
    Write-Host "  Inserted:              $($machineResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:               $($machineResult.Updated)" -ForegroundColor White
    Write-Host "Employee Identities:     $($identityObjects.Count)" -ForegroundColor White
    Write-Host "  Inserted:              $($identityResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:               $($identityResult.Updated)" -ForegroundColor White
    Write-Host "  Deleted:               $($identityResult.Deleted)" -ForegroundColor White
    Write-Host "Identity Members:        $($identityMemberObjects.Count)" -ForegroundColor White
    Write-Host "  Inserted:              $($memberResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:               $($memberResult.Updated)" -ForegroundColor White
    if ($unmatchedCount -gt 0) {
        Write-Host "Unmatched identities:    $unmatchedCount" -ForegroundColor Yellow
    }
    Write-Host "`nAll changes tracked in temporal tables" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalRecords = $csvData.Count
        MachinePrincipals = @{
            Total = $machinePrincipalObjects.Count
            Inserted = $machineResult.Inserted
            Updated = $machineResult.Updated
        }
        Identities = @{
            Total = $identityObjects.Count
            Inserted = $identityResult.Inserted
            Updated = $identityResult.Updated
            Deleted = $identityResult.Deleted
        }
        IdentityMembers = @{
            Total = $identityMemberObjects.Count
            Inserted = $memberResult.Inserted
            Updated = $memberResult.Updated
        }
        UnmatchedIdentities = $unmatchedCount
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVIdentities" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName $TableName
    }
}
