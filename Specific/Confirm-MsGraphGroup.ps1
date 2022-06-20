function Confirm-MsGraphGroup {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$GroupName,
        [Parameter(Mandatory = $false)]
        [string]$GroupDescription
    )

    #Check if group exists only once
    [array]$Group = Get-MsGraphGroup -GroupName $GroupName
    if ($Group.count -eq 1) {
        Write-Host "Confirmed Group exists: $GroupName" -ForegroundColor Green

        If ($GroupDescription) {
            If ($Group.Description -eq $GroupDescription) {
                Write-Host ("Confirmed Group Description: " + $GroupDescription) -ForegroundColor Green
            }
            else {
                Write-Host ("Setting Group Description: " + $GroupDescription ) -ForegroundColor Red
                $Updates = @{description = $GroupDescription }
                Set-MsGraphGroup -ObjectId $Group[0].id -Updates $Updates
            }
        }
    }
    elseif ($Group.count -gt 1) {
        throw "More then one group found with name: $GroupName"
    }
    else {
        Write-Host ("Creating Group:" + $GroupName) -ForegroundColor Yellow
        If ($GroupDescription) {
            $Group = @{
                displayName     = $GroupName
                description     = $GroupDescription
                groupTypes      = @()
                mailEnabled     = $false
                mailNickname    = $GroupName.Replace(" ", "").ToLower()
                securityEnabled = $true
            }
        }
        else {
            $Group = @{
                displayName     = $GroupName
                groupTypes      = @()
                mailEnabled     = $false
                mailNickname    = $GroupName.Replace(" ", "").ToLower()
                securityEnabled = $true
            }
        }        

        #Create Group
        New-MsGraphGroup -Group $Group

        #Get Group with all attributes.. including the object ID
        Start-sleep -s 30
        $Group = Get-MsGraphGroup -GroupName $GroupName
    }

    return $Group
   
}