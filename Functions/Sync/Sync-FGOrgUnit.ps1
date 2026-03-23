function Sync-FGOrgUnit {
    <#
    .SYNOPSIS
    Calculates organizational units from Principals data and syncs to the OrgUnits table.

    .DESCRIPTION
    Extracts unique departments from the Principals table and creates OrgUnit records.
    For each department:
    - Generates a deterministic GUID based on systemId + department name
    - Counts members (direct and total)
    - Identifies the department manager (principal with most direct reports in that department)
    - Infers parent-child relationships from manager chains
    - Updates orgUnitId on Principals and Identities tables

    .PARAMETER SystemId
    Optional system ID. If not provided, auto-detects from Systems table where systemType='EntraID'.

    .EXAMPLE
    Sync-FGOrgUnit
    #>

    [CmdletBinding()]
    [Alias("Sync-OrgUnit")]
    Param(
        [Parameter(Mandatory = $false)]
        [int]$SystemId
    )

    $syncStartTime = Get-Date
    $syncStatus = "Failed"
    $syncErrorMessage = $null
    $syncRecordCount = 0

    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    try {

    # Resolve SystemId
    if (-not $SystemId) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Auto-detecting system ID for EntraID..." -ForegroundColor Cyan
        $SystemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -DisplayName 'Entra ID'
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Using system ID: $SystemId" -ForegroundColor Green
    }

    # Ensure OrgUnits table exists
    $orgUnitColumns = @{
        'id'                 = 'UNIQUEIDENTIFIER'
        'systemId'           = 'INT'
        'displayName'        = 'NVARCHAR(500)'
        'orgUnitType'        = 'NVARCHAR(50)'
        'parentOrgUnitId'    = 'UNIQUEIDENTIFIER'
        'managerId'          = 'UNIQUEIDENTIFIER'
        'managerIdentityId'  = 'UNIQUEIDENTIFIER'
        'department'         = 'NVARCHAR(255)'
        'division'           = 'NVARCHAR(255)'
        'costCenter'         = 'NVARCHAR(255)'
        'officeLocation'     = 'NVARCHAR(255)'
        'memberCount'        = 'INT'
        'totalMemberCount'   = 'INT'
        'sourceType'         = 'NVARCHAR(50)'
        'lastCalculatedAt'   = 'DATETIME2'
        'extendedAttributes' = 'NVARCHAR(MAX)'
    }
    Initialize-FGSyncTable -TableName "OrgUnits" -Columns $orgUnitColumns -PrimaryKey 'id'

    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] Calculating organizational units from Principals..." -ForegroundColor Cyan

    # Use a direct connection for all data loading (avoids Invoke-FGSQLCommand pipeline issues)
    $dataConnection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $dataConnection.Open()

    try {
        # Load departments from Principals
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = @"
SELECT
    department,
    (SELECT TOP 1 companyName FROM dbo.Principals p2
     WHERE p2.department = p.department AND p2.companyName IS NOT NULL
     AND p2.ValidTo = '9999-12-31 23:59:59.9999999' AND p2.principalType = 'User') as companyName,
    COUNT(*) as memberCount
FROM dbo.Principals p
WHERE principalType = 'User'
  AND ValidTo = '9999-12-31 23:59:59.9999999'
  AND department IS NOT NULL
  AND department != ''
GROUP BY department
ORDER BY department
"@
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $deptTable = New-Object System.Data.DataTable
        $adapter.Fill($deptTable) | Out-Null

        $departments = @()
        foreach ($row in $deptTable.Rows) {
            $departments += @{
                department = "$($row['department'])"
                companyName = if ($row['companyName'] -is [DBNull]) { $null } else { "$($row['companyName'])" }
                memberCount = [int]$row['memberCount']
            }
        }
        $deptTable.Dispose()

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found $($departments.Count) departments" -ForegroundColor Green

        if ($departments.Count -eq 0) {
            Write-Warning "No departments found in Principals table."
            $syncStatus = "Success"
            return
        }

        # Find department managers (person with most direct reports in each dept)
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = @"
WITH DeptReports AS (
    SELECT
        mgr.id AS managerId,
        mgr.department,
        COUNT(rep.id) AS reportCount
    FROM dbo.Principals mgr
    INNER JOIN dbo.Principals rep ON rep.managerId = mgr.id
        AND rep.ValidTo = '9999-12-31 23:59:59.9999999'
        AND rep.principalType = 'User'
    WHERE mgr.ValidTo = '9999-12-31 23:59:59.9999999'
      AND mgr.principalType = 'User'
      AND mgr.department IS NOT NULL AND mgr.department != ''
    GROUP BY mgr.id, mgr.department
),
RankedManagers AS (
    SELECT managerId, department, reportCount,
           ROW_NUMBER() OVER (PARTITION BY department ORDER BY reportCount DESC) as rn
    FROM DeptReports
)
SELECT managerId, department FROM RankedManagers WHERE rn = 1
"@
        $reader = $cmd.ExecuteReader()
        $deptManagers = @{}
        while ($reader.Read()) {
            $deptManagers["$($reader['department'])"] = "$($reader['managerId'])"
        }
        $reader.Close()

        # Find manager departments (to infer parent-child OrgUnit relationships)
        $cmd = $dataConnection.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = @"
SELECT DISTINCT
    p.department AS childDept,
    mgr.department AS parentDept
FROM dbo.Principals p
INNER JOIN dbo.Principals mgr ON p.managerId = mgr.id
    AND mgr.ValidTo = '9999-12-31 23:59:59.9999999'
WHERE p.ValidTo = '9999-12-31 23:59:59.9999999'
  AND p.principalType = 'User'
  AND p.department IS NOT NULL AND p.department != ''
  AND mgr.department IS NOT NULL AND mgr.department != ''
  AND p.department != mgr.department
"@
        $reader = $cmd.ExecuteReader()
        $managerDepts = @{}
        while ($reader.Read()) {
            $child = "$($reader['childDept'])"
            $parent = "$($reader['parentDept'])"
            if (-not $managerDepts.ContainsKey($child)) {
                $managerDepts[$child] = $parent
            }
        }
        $reader.Close()
    } finally {
        if ($dataConnection.State -eq 'Open') { $dataConnection.Close() }
        $dataConnection.Dispose()
    }

    # Generate deterministic GUIDs for departments
    $md5 = [System.Security.Cryptography.MD5]::Create()

    function Get-DeterministicGuid([string]$InputValue) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputValue)
        $hash = $md5.ComputeHash($bytes)
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        $guidStr = $hex.Substring(0,8) + '-' + $hex.Substring(8,4) + '-' + $hex.Substring(12,4) + '-' + $hex.Substring(16,4) + '-' + $hex.Substring(20,12)
        return [guid]$guidStr
    }

    # Build OrgUnit records
    $orgUnits = @()
    $deptToGuid = @{}
    $now = [datetime]::UtcNow

    foreach ($dept in $departments) {
        $deptName = $dept.department
        $guidInput = "$SystemId|$deptName"
        $orgUnitId = Get-DeterministicGuid $guidInput
        $deptToGuid[$deptName] = $orgUnitId

        $mgrId = if ($deptManagers.ContainsKey($deptName)) { [guid]$deptManagers[$deptName] } else { $null }

        $orgUnits += [PSCustomObject]@{
            id = $orgUnitId
            systemId = $SystemId
            displayName = $deptName
            orgUnitType = 'Department'
            parentOrgUnitId = $null
            managerId = $mgrId
            managerIdentityId = $null
            department = $deptName
            division = $dept.companyName
            costCenter = $null
            officeLocation = $null
            memberCount = $dept.memberCount
            totalMemberCount = $dept.memberCount
            sourceType = 'Calculated'
            lastCalculatedAt = $now
            extendedAttributes = $null
        }
    }

    # Set parent OrgUnit IDs based on manager department relationships
    foreach ($ou in $orgUnits) {
        if ($managerDepts.ContainsKey($ou.department)) {
            $parentDept = $managerDepts[$ou.department]
            if ($deptToGuid.ContainsKey($parentDept)) {
                $ou.parentOrgUnitId = $deptToGuid[$parentDept]
            }
        }
    }

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Built $($orgUnits.Count) OrgUnit records" -ForegroundColor Green

    # Build DataTable
    $dataTable = New-Object System.Data.DataTable
    $dataTable.Columns.Add("id", [guid]) | Out-Null
    $dataTable.Columns.Add("systemId", [int]) | Out-Null
    $dataTable.Columns.Add("displayName", [string]) | Out-Null
    $dataTable.Columns.Add("orgUnitType", [string]) | Out-Null
    $dataTable.Columns.Add("parentOrgUnitId", [guid]) | Out-Null
    $dataTable.Columns.Add("managerId", [guid]) | Out-Null
    $dataTable.Columns.Add("managerIdentityId", [guid]) | Out-Null
    $dataTable.Columns.Add("department", [string]) | Out-Null
    $dataTable.Columns.Add("division", [string]) | Out-Null
    $dataTable.Columns.Add("costCenter", [string]) | Out-Null
    $dataTable.Columns.Add("officeLocation", [string]) | Out-Null
    $dataTable.Columns.Add("memberCount", [int]) | Out-Null
    $dataTable.Columns.Add("totalMemberCount", [int]) | Out-Null
    $dataTable.Columns.Add("sourceType", [string]) | Out-Null
    $dataTable.Columns.Add("lastCalculatedAt", [datetime]) | Out-Null
    $dataTable.Columns.Add("extendedAttributes", [string]) | Out-Null

    foreach ($ou in $orgUnits) {
        $row = $dataTable.NewRow()
        $row["id"] = $ou.id
        $row["systemId"] = $ou.systemId
        $row["displayName"] = $ou.displayName
        $row["orgUnitType"] = $ou.orgUnitType
        $row["parentOrgUnitId"] = if ($ou.parentOrgUnitId) { $ou.parentOrgUnitId } else { [DBNull]::Value }
        $row["managerId"] = if ($ou.managerId) { $ou.managerId } else { [DBNull]::Value }
        $row["managerIdentityId"] = [DBNull]::Value
        $row["department"] = if ($ou.department) { $ou.department } else { [DBNull]::Value }
        $row["division"] = if ($ou.division) { $ou.division } else { [DBNull]::Value }
        $row["costCenter"] = [DBNull]::Value
        $row["officeLocation"] = [DBNull]::Value
        $row["memberCount"] = $ou.memberCount
        $row["totalMemberCount"] = $ou.totalMemberCount
        $row["sourceType"] = $ou.sourceType
        $row["lastCalculatedAt"] = $ou.lastCalculatedAt
        $row["extendedAttributes"] = [DBNull]::Value
        $dataTable.Rows.Add($row)
    }

    # Bulk merge to SQL
    $syncResult = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)
        $transaction = $connection.BeginTransaction()
        try {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Bulk merging $($dataTable.Rows.Count) OrgUnits..." -ForegroundColor Cyan

            $mergeResult = Invoke-FGSQLBulkMerge `
                -Connection $connection `
                -Transaction $transaction `
                -TargetTableName "OrgUnits" `
                -DataTable $dataTable `
                -KeyColumns @('id')

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] OrgUnits: $($mergeResult.Inserted) inserted, $($mergeResult.Updated) updated" -ForegroundColor Green

            # Update Principals.orgUnitId based on department match
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updating Principals.orgUnitId..." -ForegroundColor Cyan
            $updateCmd = $connection.CreateCommand()
            $updateCmd.Transaction = $transaction
            $updateCmd.CommandTimeout = 300
            $updateCmd.CommandText = @"
UPDATE p SET p.orgUnitId = ou.id
FROM dbo.Principals p
INNER JOIN dbo.OrgUnits ou ON p.department = ou.department AND ou.systemId = p.systemId
WHERE p.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ou.ValidTo = '9999-12-31 23:59:59.9999999'
  AND p.principalType = 'User'
"@
            $principalsUpdated = $updateCmd.ExecuteNonQuery()
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updated orgUnitId on $principalsUpdated principals" -ForegroundColor Green

            # Update Identities.orgUnitId if Identities table has data
            $identitiesUpdated = 0
            try {
                $identUpdateCmd = $connection.CreateCommand()
                $identUpdateCmd.Transaction = $transaction
                $identUpdateCmd.CommandTimeout = 300
                $identUpdateCmd.CommandText = @"
UPDATE i SET i.orgUnitId = ou.id
FROM dbo.Identities i
INNER JOIN dbo.OrgUnits ou ON i.department = ou.department
WHERE i.ValidTo = '9999-12-31 23:59:59.9999999'
  AND ou.ValidTo = '9999-12-31 23:59:59.9999999'
"@
                $identitiesUpdated = $identUpdateCmd.ExecuteNonQuery()
                if ($identitiesUpdated -gt 0) {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updated orgUnitId on $identitiesUpdated identities" -ForegroundColor Green
                }
            } catch {
                Write-Verbose "Could not update Identities.orgUnitId: $_"
            }

            $transaction.Commit()
            $transaction.Dispose()

            return @{
                Inserted = $mergeResult.Inserted
                Updated = $mergeResult.Updated
                PrincipalsUpdated = $principalsUpdated
            }
        }
        catch {
            try { if ($transaction) { $transaction.Rollback(); $transaction.Dispose() } } catch { }
            throw
        }
    }

    $syncRecordCount = $orgUnits.Count
    $syncStatus = "Success"

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "OrgUnit Sync Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "OrgUnits:           $($orgUnits.Count)" -ForegroundColor White
    Write-Host "  Inserted:         $($syncResult.Inserted)" -ForegroundColor White
    Write-Host "  Updated:          $($syncResult.Updated)" -ForegroundColor White
    Write-Host "Principals updated: $($syncResult.PrincipalsUpdated)" -ForegroundColor White
    Write-Host "========================================`n" -ForegroundColor Green

    } catch {
        $syncErrorMessage = $_.Exception.Message
        $syncStatus = "Failed"
        throw
    }
    finally {
        Write-FGSyncLog -SyncType "OrgUnits" -StartTime $syncStartTime -RecordCount $syncRecordCount -Status $syncStatus -ErrorMessage $syncErrorMessage -TableName "OrgUnits"
    }

    return @{
        TotalOrgUnits = $orgUnits.Count
        Inserted = $syncResult.Inserted
        Updated = $syncResult.Updated
        PrincipalsUpdated = $syncResult.PrincipalsUpdated
    }
}
