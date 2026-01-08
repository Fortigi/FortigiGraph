function Remove-FGAzureSQLServer {
    <#
    .SYNOPSIS
    Removes an Azure SQL Server and all its databases.

    .DESCRIPTION
    Deletes an Azure SQL Server, including all databases, firewall rules, and associated
    resources. This is useful for cleaning up test environments or decommissioning servers.

    CAUTION: This operation is IRREVERSIBLE. All data will be permanently deleted.

    .PARAMETER SubscriptionId
    Azure Subscription ID where the SQL Server is located

    .PARAMETER ResourceGroupName
    Resource Group containing the SQL Server

    .PARAMETER ServerName
    Name of the SQL Server to remove (without .database.windows.net suffix)

    .PARAMETER Force
    Skip confirmation prompts. Use with extreme caution!

    .EXAMPLE
    Remove-FGAzureSQLServer -SubscriptionId "12345..." -ResourceGroupName "rg-test" -ServerName "fg-test-sql-123"
    Removes the specified SQL Server after confirmation

    .EXAMPLE
    Remove-FGAzureSQLServer -SubscriptionId "12345..." -ResourceGroupName "rg-test" -ServerName "fg-test-sql-123" -Force
    Removes the SQL Server without confirmation (dangerous!)

    .NOTES
    - This is a DESTRUCTIVE operation that cannot be undone
    - All databases on the server will be deleted
    - All firewall rules will be deleted
    - Any active connections will be terminated
    - Best practice: Export/backup any important data before running this
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Ensure we're connected to Azure
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-Error "Not connected to Azure. Use Connect-AzAccount first."
            return
        }

        # Set subscription context if needed
        if ($context.Subscription.Id -ne $SubscriptionId) {
            Write-Host "Switching to subscription: $SubscriptionId" -ForegroundColor Cyan
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        }
    } catch {
        Write-Error "Failed to set Azure context: $_"
        return
    }

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "Remove Azure SQL Server" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Check if server exists
    Write-Host "Checking if SQL Server exists..." -ForegroundColor Yellow
    try {
        $server = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -ErrorAction Stop
    } catch {
        if ($_.Exception.Message -like "*ResourceNotFound*") {
            Write-Host "  ✓ SQL Server does not exist: $ServerName" -ForegroundColor Green
            Write-Host "    Nothing to remove." -ForegroundColor Gray
            return
        } else {
            Write-Error "Failed to check server status: $_"
            return
        }
    }

    Write-Host "  → Found SQL Server: $ServerName" -ForegroundColor Cyan
    Write-Host "    Location: $($server.Location)" -ForegroundColor Gray
    Write-Host "    FQDN: $($server.FullyQualifiedDomainName)" -ForegroundColor Gray
    Write-Host "    Resource Group: $ResourceGroupName" -ForegroundColor Gray

    # Get databases on the server
    try {
        $databases = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName | Where-Object { $_.DatabaseName -ne "master" }
        if ($databases) {
            Write-Host "`n  → Databases that will be deleted:" -ForegroundColor Yellow
            foreach ($db in $databases) {
                $sizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)
                Write-Host "    • $($db.DatabaseName) ($($db.Edition), $sizeGB GB max)" -ForegroundColor Red
            }
        } else {
            Write-Host "`n  → No user databases found" -ForegroundColor Gray
        }
    } catch {
        Write-Warning "Could not enumerate databases: $_"
    }

    # Confirmation
    if (-not $Force) {
        Write-Host "`n⚠️  WARNING: This will PERMANENTLY delete:" -ForegroundColor Red
        Write-Host "   • SQL Server: $ServerName" -ForegroundColor Red
        Write-Host "   • All databases on this server" -ForegroundColor Red
        Write-Host "   • All firewall rules" -ForegroundColor Red
        Write-Host "   • All data (CANNOT BE RECOVERED)" -ForegroundColor Red

        if (-not $PSCmdlet.ShouldProcess($ServerName, "PERMANENTLY DELETE SQL Server and all databases")) {
            Write-Host "`nOperation cancelled." -ForegroundColor Yellow
            return
        }

        # Extra confirmation for production-sounding names
        if ($ServerName -notlike "*test*" -and $ServerName -notlike "*dev*" -and $ServerName -notlike "*demo*") {
            Write-Host "`n⚠️  This doesn't look like a test server!" -ForegroundColor Red
            $confirmation = Read-Host "Type the server name '$ServerName' to confirm deletion"
            if ($confirmation -ne $ServerName) {
                Write-Host "Server name didn't match. Operation cancelled." -ForegroundColor Yellow
                return
            }
        }
    }

    # Close any active connections
    if ($global:FGSQLConnectionString -and $global:FGSQLServerName -like "$ServerName*") {
        Write-Host "`n  → Clearing active SQL connection..." -ForegroundColor Cyan
        try {
            $global:FGSQLConnectionString = $null
            Write-Host "  ✓ Connection cleared" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to clear connection: $_"
        }
    }

    # Remove the SQL Server
    Write-Host "`n  → Removing SQL Server..." -ForegroundColor Yellow
    Write-Host "    This may take several minutes..." -ForegroundColor Gray

    try {
        Remove-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $ServerName -Force

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "✓ SQL Server Removed Successfully" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green

        Write-Host "`nRemoved:" -ForegroundColor White
        Write-Host "  • Server: $ServerName" -ForegroundColor Gray
        Write-Host "  • Resource Group: $ResourceGroupName" -ForegroundColor Gray
        if ($databases) {
            Write-Host "  • Databases: $($databases.Count)" -ForegroundColor Gray
        }

        # Clear global variables if they reference this server
        if ($global:FGSQLServerName -like "$ServerName*") {
            $global:FGSQLServerName = $null
            $global:FGSQLDatabaseName = $null
            $global:FGSQLAdminUsername = $null
            Write-Host "`n  → Cleared global connection variables" -ForegroundColor Cyan
        }

    } catch {
        Write-Host "`n========================================" -ForegroundColor Red
        Write-Host "✗ Failed to Remove SQL Server" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Error "Removal failed: $_"

        Write-Host "`nTroubleshooting:" -ForegroundColor Yellow
        Write-Host "  1. Check if you have permissions to delete the server" -ForegroundColor Gray
        Write-Host "  2. Verify the server name and resource group are correct" -ForegroundColor Gray
        Write-Host "  3. Check if there are resource locks preventing deletion" -ForegroundColor Gray
        Write-Host "  4. Try again in a few minutes if Azure is experiencing issues" -ForegroundColor Gray
    }
}
