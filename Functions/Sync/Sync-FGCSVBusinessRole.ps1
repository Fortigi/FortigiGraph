function Sync-FGCSVBusinessRole {
    <#
    .SYNOPSIS
    Syncs business roles, policies, and resource mappings from a semicolon-delimited CSV file (AssignmentPolicies.csv).

    .DESCRIPTION
    Loads AssignmentPolicies.csv and extracts three entity types into separate SQL tables:
    - BusinessRoles — unique business roles from distinct AP_ID values
    - BusinessRolePolicies — one per unique (AP_ID, CONTEXTNAME) combination
    - BusinessRoleResources — one per unique (AP_ID, RESOURCEUID) combination

    Uses deterministic GUIDs based on composite keys to ensure idempotent syncs.
    Uses the global $FGCSVSystemLookup hashtable for system ID resolution.

    .PARAMETER Path
    Path to the AssignmentPolicies.csv file (semicolon-delimited, quoted, UTF8).

    .EXAMPLE
    Sync-FGCSVBusinessRole -Path ".\data\AssignmentPolicies.csv"

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - $Global:FGCSVSystemLookup hashtable populated (system name -> systemId INT)
    #>

    [CmdletBinding()]
    [Alias("Sync-CSVBusinessRole")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

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

    # Check system lookup
    if (-not $Global:FGCSVSystemLookup -or $Global:FGCSVSystemLookup.Count -eq 0) {
        throw "Global system lookup is empty. Please populate `$Global:FGCSVSystemLookup before calling this function."
    }

    try {

    # --- Table definitions ---

    $brColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $brpColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'businessRoleId'     = 'UNIQUEIDENTIFIER'
        'displayName'        = 'NVARCHAR(500)'
        'policyConditions'   = 'NVARCHAR(MAX)'
        'allowedTargetScope' = 'NVARCHAR(500)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    $brrColumns = @{
        'id'                 = 'NVARCHAR(500)'
        'businessRoleId'     = 'UNIQUEIDENTIFIER'
        'resourceId'         = 'UNIQUEIDENTIFIER'
        'roleName'           = 'NVARCHAR(500)'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }

    # Ensure tables exist
    $tableReady1 = Initialize-FGSyncTable -TableName "BusinessRoles" -Columns $brColumns -PrimaryKey 'id'
    if ($tableReady1 -eq $false) { return }

    $tableReady2 = Initialize-FGSyncTable -TableName "BusinessRolePolicies" -Columns $brpColumns -PrimaryKey 'id'
    if ($tableReady2 -eq $false) { return }

    $tableReady3 = Initialize-FGSyncTable -TableName "BusinessRoleResources" -Columns $brrColumns -PrimaryKey 'id'
    if ($tableReady3 -eq $false) { return }

    # Load CSV
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Loading CSV from $Path..." -ForegroundColor Cyan

    if (-not (Test-Path $Path)) {
        throw "CSV file not found: $Path"
    }

    $csvData = Import-Csv -Path $Path -Delimiter ';' -Encoding UTF8
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Loaded $($csvData.Count) rows from CSV" -ForegroundColor Green

    if ($csvData.Count -eq 0) {
        Write-Warning "[$(Get-Date -Format 'HH:mm:ss')] No rows found in CSV."
        $syncStatus = "Success"
        $syncRecordCount = 0
        return
    }

    # --- Extract BusinessRoles (unique AP_ID) ---
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Extracting BusinessRoles from CSV..." -ForegroundColor Cyan

    $brGrouped = $csvData | Group-Object -Property AP_ID
    $businessRoles = @()

    foreach ($group in $brGrouped) {
        $firstRow = $group.Group[0]
        $apId = $firstRow.AP_ID

        # Look up systemId from the parent Omada system
        $systemId = $null
        foreach ($key in $Global:FGCSVSystemLookup.Keys) {
            $systemId = $Global:FGCSVSystemLookup[$key]
            break
        }

        $extendedAttrs = @{}
        if ($firstRow.PSObject.Properties.Name -contains 'AP_UID' -and $firstRow.AP_UID) { $extendedAttrs['AP_UID'] = $firstRow.AP_UID }
        if ($firstRow.PSObject.Properties.Name -contains 'AP_IDENTITYVIEW' -and $firstRow.AP_IDENTITYVIEW) { $extendedAttrs['AP_IDENTITYVIEW'] = $firstRow.AP_IDENTITYVIEW }
        if ($firstRow.PSObject.Properties.Name -contains 'AP_NAME' -and $firstRow.AP_NAME) { $extendedAttrs['AP_NAME'] = $firstRow.AP_NAME }
        if ($firstRow.PSObject.Properties.Name -contains 'VALIDFROM' -and $firstRow.VALIDFROM) { $extendedAttrs['VALIDFROM'] = $firstRow.VALIDFROM }
        if ($firstRow.PSObject.Properties.Name -contains 'VALIDTO' -and $firstRow.VALIDTO) { $extendedAttrs['VALIDTO'] = $firstRow.VALIDTO }

        $businessRoles += [PSCustomObject]@{
            id                 = New-DeterministicGuid -InputString "businessrole:$apId"
            systemId           = $systemId
            displayName        = $firstRow.NAME
            extendedAttributes = if ($extendedAttrs.Count -gt 0) { $extendedAttrs | ConvertTo-Json -Depth 10 -Compress } else { $null }
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Extracted $($businessRoles.Count) unique BusinessRoles" -ForegroundColor Green

    # --- Extract BusinessRolePolicies (unique AP_ID + CONTEXTNAME) ---
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Extracting BusinessRolePolicies from CSV..." -ForegroundColor Cyan

    $brpGrouped = $csvData | Group-Object -Property { "$($_.AP_ID)|$($_.CONTEXTNAME)" }
    $businessRolePolicies = @()

    foreach ($group in $brpGrouped) {
        $firstRow = $group.Group[0]
        $apId = $firstRow.AP_ID
        $contextName = $firstRow.CONTEXTNAME

        $policyConditions = @{
            contextName = $contextName
            contextUID  = $firstRow.CONTEXTUID
        } | ConvertTo-Json -Depth 10 -Compress

        $extendedAttrs = @{}
        if ($firstRow.PSObject.Properties.Name -contains 'AP_ONLYDIRECTCTXASSN' -and $firstRow.AP_ONLYDIRECTCTXASSN) { $extendedAttrs['AP_ONLYDIRECTCTXASSN'] = $firstRow.AP_ONLYDIRECTCTXASSN }
        if ($firstRow.PSObject.Properties.Name -contains 'AP_IDENTITYVIEW' -and $firstRow.AP_IDENTITYVIEW) { $extendedAttrs['AP_IDENTITYVIEW'] = $firstRow.AP_IDENTITYVIEW }

        $businessRolePolicies += [PSCustomObject]@{
            id                 = New-DeterministicGuid -InputString "policy:${apId}:${contextName}"
            businessRoleId     = New-DeterministicGuid -InputString "businessrole:$apId"
            displayName        = $firstRow.NAME
            policyConditions   = $policyConditions
            allowedTargetScope = $firstRow.AP_NAME
            extendedAttributes = if ($extendedAttrs.Count -gt 0) { $extendedAttrs | ConvertTo-Json -Depth 10 -Compress } else { $null }
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Extracted $($businessRolePolicies.Count) unique BusinessRolePolicies" -ForegroundColor Green

    # --- Extract BusinessRoleResources (unique AP_ID + RESOURCEUID) ---
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Extracting BusinessRoleResources from CSV..." -ForegroundColor Cyan

    $brrGrouped = $csvData | Group-Object -Property { "$($_.AP_ID)|$($_.RESOURCEUID)" }
    $businessRoleResources = @()

    foreach ($group in $brrGrouped) {
        $firstRow = $group.Group[0]
        $apId = $firstRow.AP_ID
        $resourceUid = $firstRow.RESOURCEUID

        # Try to cast RESOURCEUID as GUID; if invalid, generate deterministic
        $resourceId = $null
        try {
            $resourceId = [guid]$resourceUid
        }
        catch {
            $resourceId = New-DeterministicGuid -InputString "resource:$resourceUid"
        }

        $extendedAttrs = @{
            CONTEXTNAME = $firstRow.CONTEXTNAME
            CONTEXTUID  = $firstRow.CONTEXTUID
        }

        $businessRoleResources += [PSCustomObject]@{
            id                 = "$($apId)_$($resourceUid)"
            businessRoleId     = New-DeterministicGuid -InputString "businessrole:$apId"
            resourceId         = $resourceId
            roleName           = $firstRow.RESOURCENAME
            extendedAttributes = $extendedAttrs | ConvertTo-Json -Depth 10 -Compress
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Extracted $($businessRoleResources.Count) unique BusinessRoleResources" -ForegroundColor Green

    # --- Build DataTables ---
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Preparing data for bulk sync..." -ForegroundColor Cyan

    $brAttributes = @('id', 'systemId', 'displayName', 'extendedAttributes')
    $brDataTable = New-FGDataTableFromGraphObjects -GraphObjects $businessRoles -Columns $brColumns -Attributes $brAttributes

    $brpAttributes = @('id', 'businessRoleId', 'displayName', 'policyConditions', 'allowedTargetScope', 'extendedAttributes')
    $brpDataTable = New-FGDataTableFromGraphObjects -GraphObjects $businessRolePolicies -Columns $brpColumns -Attributes $brpAttributes

    $brrAttributes = @('id', 'businessRoleId', 'resourceId', 'roleName', 'extendedAttributes')
    $brrDataTable = New-FGDataTableFromGraphObjects -GraphObjects $businessRoleResources -Columns $brrColumns -Attributes $brrAttributes

    # --- Sync all three tables ---
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing BusinessRoles to SQL Server..." -ForegroundColor Cyan

    $brResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($brDataTable.Rows.Count) BusinessRoles..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRoles" `
                -DataTable $brDataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BusinessRoles: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRoles" `
                -DataTable $brDataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale BusinessRoles" -ForegroundColor Yellow
            }

            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated  = $mergeResult.Updated
                Deleted  = $deletedCount
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during BusinessRoles sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing BusinessRolePolicies to SQL Server..." -ForegroundColor Cyan

    $brpResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($brpDataTable.Rows.Count) BusinessRolePolicies..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRolePolicies" `
                -DataTable $brpDataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BusinessRolePolicies: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRolePolicies" `
                -DataTable $brpDataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale BusinessRolePolicies" -ForegroundColor Yellow
            }

            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated  = $mergeResult.Updated
                Deleted  = $deletedCount
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during BusinessRolePolicies sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Syncing BusinessRoleResources to SQL Server..." -ForegroundColor Cyan

    $brrResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        $transaction = $connection.BeginTransaction()

        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($brrDataTable.Rows.Count) BusinessRoleResources..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRoleResources" `
                -DataTable $brrDataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BusinessRoleResources: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            $deletedCount = Invoke-FGSQLBulkDelete `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "BusinessRoleResources" `
                -DataTable $brrDataTable `
                -KeyColumns @('id')

            if ($deletedCount -gt 0) {
                Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] Deleted $deletedCount stale BusinessRoleResources" -ForegroundColor Yellow
            }

            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated  = $mergeResult.Updated
                Deleted  = $deletedCount
            }
        }
        catch {
            Write-Error "[$(Get-Date -Format 'HH:mm:ss')] Failed during BusinessRoleResources sync: $_"
            if ($transaction) {
                $transaction.Rollback()
                $transaction.Dispose()
            }
            throw
        }
    }

    $syncRecordCount = $csvData.Count

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "CSV Business Role Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "CSV Rows:                  $($csvData.Count)" -ForegroundColor White
    Write-Host "BusinessRoles:             $($businessRoles.Count) (I:$($brResult.Inserted) U:$($brResult.Updated) D:$($brResult.Deleted))" -ForegroundColor White
    Write-Host "BusinessRolePolicies:      $($businessRolePolicies.Count) (I:$($brpResult.Inserted) U:$($brpResult.Updated) D:$($brpResult.Deleted))" -ForegroundColor White
    Write-Host "BusinessRoleResources:     $($businessRoleResources.Count) (I:$($brrResult.Inserted) U:$($brrResult.Updated) D:$($brrResult.Deleted))" -ForegroundColor White
    Write-Host "`nAll changes tracked in temporal history tables" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Green

    $syncStatus = "Success"

    return @{
        TotalCSVRows           = $csvData.Count
        BusinessRoles          = $brResult
        BusinessRolePolicies   = $brpResult
        BusinessRoleResources  = $brrResult
    }

    } # End try
    catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        # Write sync log entry
        Write-FGSyncLog -SyncType "CSVBusinessRoles" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "BusinessRoles"
    }
}
