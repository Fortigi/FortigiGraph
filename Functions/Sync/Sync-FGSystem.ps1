function Sync-FGSystem {
    <#
    .SYNOPSIS
    Ensures a System record exists in the Systems table and returns the systemId.

    .DESCRIPTION
    Helper function that manages System records in the universal resource model:
    - Checks if a system with matching systemType AND tenantId exists
    - If yes, returns its id
    - If no, creates it and returns the new id
    - Optionally updates lastSyncDateTime, resourceTypes, and assignmentTypes

    Called by sync functions (Sync-FGEntraDirectoryRole, Sync-FGEntraAppRoleAssignment, etc.)
    before syncing resources to ensure the parent system record exists.

    .PARAMETER SystemType
    Type of the system (e.g., 'EntraID', 'AzureAD', 'ServiceNow', 'SAP').

    .PARAMETER DisplayName
    Display name for the system. If not specified, defaults to SystemType.

    .PARAMETER TenantId
    Tenant ID or unique identifier for the system instance.

    .PARAMETER Description
    Optional description of the system.

    .PARAMETER UpdateLastSync
    If specified, updates lastSyncDateTime to the current time.

    .PARAMETER UpdateResourceTypes
    JSON array of resource types to set on the system record (e.g., '["EntraGroup","EntraDirectoryRole"]').

    .PARAMETER UpdateAssignmentTypes
    JSON array of assignment types to set on the system record (e.g., '["Direct","Owner","Eligible"]').

    .EXAMPLE
    $systemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -DisplayName 'Contoso Entra ID'

    Ensures an EntraID system exists and returns its id

    .EXAMPLE
    $systemId = Sync-FGSystem -SystemType 'EntraID' -TenantId $Global:TenantId -UpdateLastSync

    Returns the system id and updates the last sync timestamp

    .NOTES
    Requires:
    - Connect-FGSQLServer to be called first
    - Systems table to exist (run Initialize-FGSystemTables first)
    #>

    [CmdletBinding()]
    [Alias("Sync-System")]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$SystemType,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [switch]$UpdateLastSync,

        [Parameter(Mandatory = $false)]
        [string]$UpdateResourceTypes,

        [Parameter(Mandatory = $false)]
        [string]$UpdateAssignmentTypes
    )

    # Check SQL connection
    if (-not $global:FGSQLConnectionString) {
        throw "Not connected to SQL Server. Please run Connect-FGSQLServer first."
    }

    if (-not $DisplayName) {
        $DisplayName = $SystemType
    }

    $systemId = Invoke-FGSQLCommand -ScriptBlock {
        param($connection)

        # Check if system already exists
        $checkCmd = $connection.CreateCommand()

        if ($TenantId) {
            $checkCmd.CommandText = "SELECT id FROM dbo.Systems WHERE systemType = @systemType AND tenantId = @tenantId AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $checkCmd.Parameters.AddWithValue("@systemType", $SystemType) | Out-Null
            $checkCmd.Parameters.AddWithValue("@tenantId", $TenantId) | Out-Null
        }
        else {
            $checkCmd.CommandText = "SELECT id FROM dbo.Systems WHERE systemType = @systemType AND tenantId IS NULL AND ValidTo = '9999-12-31 23:59:59.9999999'"
            $checkCmd.Parameters.AddWithValue("@systemType", $SystemType) | Out-Null
        }

        $existingId = $checkCmd.ExecuteScalar()

        if ($null -ne $existingId) {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Found existing system '$SystemType' (id: $existingId)" -ForegroundColor Gray

            # Update fields if requested
            $updates = @()
            $updateCmd = $connection.CreateCommand()
            $paramIndex = 0

            if ($UpdateLastSync) {
                $updates += "lastSyncDateTime = @lastSync"
                $updateCmd.Parameters.AddWithValue("@lastSync", [datetime]::UtcNow) | Out-Null
            }

            if ($UpdateResourceTypes) {
                $updates += "resourceTypes = @resourceTypes"
                $updateCmd.Parameters.AddWithValue("@resourceTypes", $UpdateResourceTypes) | Out-Null
            }

            if ($UpdateAssignmentTypes) {
                $updates += "assignmentTypes = @assignmentTypes"
                $updateCmd.Parameters.AddWithValue("@assignmentTypes", $UpdateAssignmentTypes) | Out-Null
            }

            if ($updates.Count -gt 0) {
                $updateCmd.CommandText = "UPDATE dbo.Systems SET $($updates -join ', ') WHERE id = @id"
                $updateCmd.Parameters.AddWithValue("@id", $existingId) | Out-Null
                $updateCmd.ExecuteNonQuery() | Out-Null
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Updated system record" -ForegroundColor Gray
            }

            return $existingId
        }
        else {
            # Create new system
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Creating new system '$SystemType'..." -ForegroundColor Cyan

            $insertCmd = $connection.CreateCommand()
            $insertCmd.CommandText = @"
INSERT INTO dbo.Systems (systemType, displayName, description, tenantId, enabled, syncEnabled, lastSyncDateTime, resourceTypes, assignmentTypes)
OUTPUT INSERTED.id
VALUES (@systemType, @displayName, @description, @tenantId, 1, 1, @lastSync, @resourceTypes, @assignmentTypes)
"@
            $insertCmd.Parameters.AddWithValue("@systemType", $SystemType) | Out-Null
            $insertCmd.Parameters.AddWithValue("@displayName", $DisplayName) | Out-Null
            $insertCmd.Parameters.AddWithValue("@description", $(if ($Description) { $Description } else { [DBNull]::Value })) | Out-Null
            $insertCmd.Parameters.AddWithValue("@tenantId", $(if ($TenantId) { $TenantId } else { [DBNull]::Value })) | Out-Null
            $insertCmd.Parameters.AddWithValue("@lastSync", $(if ($UpdateLastSync) { [datetime]::UtcNow } else { [DBNull]::Value })) | Out-Null
            $insertCmd.Parameters.AddWithValue("@resourceTypes", $(if ($UpdateResourceTypes) { $UpdateResourceTypes } else { [DBNull]::Value })) | Out-Null
            $insertCmd.Parameters.AddWithValue("@assignmentTypes", $(if ($UpdateAssignmentTypes) { $UpdateAssignmentTypes } else { [DBNull]::Value })) | Out-Null

            $newId = $insertCmd.ExecuteScalar()
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Created system '$SystemType' (id: $newId)" -ForegroundColor Green

            return $newId
        }
    }

    return $systemId
}
