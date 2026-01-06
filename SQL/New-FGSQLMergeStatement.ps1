function New-FGSQLMergeStatement {
    <#
    .SYNOPSIS
    Builds a SQL MERGE statement for upserting Graph data.

    .DESCRIPTION
    Creates an optimized MERGE statement that only updates rows when values have changed,
    properly handling NULL values and different data types.

    .PARAMETER TableName
    Name of the target table

    .PARAMETER Attributes
    Array of attribute/column names

    .PARAMETER TypeMap
    Hashtable mapping attribute names to SQL data types

    .PARAMETER PrimaryKey
    Name of the primary key column(s). Can be a single string or array of strings for composite keys. Default: 'id'

    .EXAMPLE
    $mergeSQL = New-FGSQLMergeStatement -TableName "GraphUsers" -Attributes @('id', 'displayName', 'mail') -TypeMap $typeMap

    .EXAMPLE
    $mergeSQL = New-FGSQLMergeStatement -TableName "GroupMembers" -Attributes @('groupId', 'memberId', 'memberType') -TypeMap $typeMap -PrimaryKey @('groupId', 'memberId')

    .NOTES
    The MERGE statement uses proper NULL handling and type-aware comparisons.
    Supports both single and composite primary keys.
    #>

    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [Parameter(Mandatory = $true)]
        [string[]]$Attributes,

        [Parameter(Mandatory = $true)]
        [hashtable]$TypeMap,

        [Parameter(Mandatory = $false)]
        $PrimaryKey = 'id'
    )

    # Handle composite or single primary key
    if ($PrimaryKey -is [array]) {
        $pkArray = $PrimaryKey
    } else {
        $pkArray = @($PrimaryKey)
    }

    # Build source columns (e.g., "@id AS id, @displayName AS displayName")
    $sourceColumns = ($Attributes | ForEach-Object { "@$_ AS [$_]" }) -join ', '

    # Build UPDATE SET statements (exclude primary key columns)
    $updateSetStatements = ($Attributes | Where-Object { $_ -notin $pkArray } | ForEach-Object { "[$_] = source.[$_]" }) -join ', '

    # Build INSERT columns and values
    $insertColumns = ($Attributes | ForEach-Object { "[$_]" }) -join ', '
    $insertValues = ($Attributes | ForEach-Object { "source.[$_]" }) -join ', '

    # Build ON clause for primary key matching (supports composite keys)
    $onConditions = ($pkArray | ForEach-Object { "target.[$_] = source.[$_]" }) -join ' AND '

    # Build change detection conditions (only update if something changed, exclude PK columns)
    $changeConditions = ($Attributes | Where-Object { $_ -notin $pkArray } | ForEach-Object {
        $attr = $_
        $sqlType = $TypeMap[$attr]

        # Use proper NULL handling for all types
        "((target.[$attr] IS NULL AND source.[$attr] IS NOT NULL) OR (target.[$attr] IS NOT NULL AND source.[$attr] IS NULL) OR (target.[$attr] <> source.[$attr]))"
    }) -join ' OR '

    # Build the MERGE statement
    $mergeSQL = @"
MERGE dbo.$TableName AS target
USING (SELECT $sourceColumns) AS source
ON $onConditions
WHEN MATCHED AND ($changeConditions) THEN
    UPDATE SET $updateSetStatements
WHEN NOT MATCHED THEN
    INSERT ($insertColumns)
    VALUES ($insertValues);
"@

    return $mergeSQL
}
