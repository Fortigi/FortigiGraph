function Invoke-FGSQLQuery {
    param(
        [string]$Query
    )
    
    $connection = New-Object System.Data.SqlClient.SqlConnection($global:FGSQLConnectionString)
    $connection.Open()
    
    $cmd = $connection.CreateCommand()
    $cmd.CommandText = $Query
    
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dataset = New-Object System.Data.DataSet
    $adapter.Fill($dataset) | Out-Null
    
    $connection.Close()
    
    return $dataset.Tables[0]
}