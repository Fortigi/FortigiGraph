cd C:\Source\Fortigi\GitHub\FortigiGraph

Import-Module .\FortigiGraph.psm1 -Force

$SubscriptionId = "6af08f87-5594-49ed-a029-976707a2a70b"
$ResourceGroupName = "SQLServer4"
$ServerName = "iisqlserver4"
$DatabaseName = "GraphData"

Connect-FGSQLServer -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName

Invoke-FGSQLQuery -Query "SELECT * FROM dbo.GraphUsers"