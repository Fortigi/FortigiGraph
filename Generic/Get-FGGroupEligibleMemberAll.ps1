function Get-FGGroupEligibleMemberAll {
    [alias("Get-GroupEligibleMemberAll")]

    #Get Groups
    $GraphURI = 'https://graph.microsoft.com/beta'
    $URI = $GraphURI + '/groups?$select=id,isAssignableToRole,groupTypes'
    [array]$Groups = Invoke-FGGetRequest -URI $URI

    #This is no way to do this with one qeury we need to do it group by group or user by user.
    #Filter Groups that can't used in PIM
    $PIMGroups = $Groups | Where-Object { $_.IsAssignableToRole -eq $true }
    $PIMGroups = $PIMGroups | Where-Object { $_.groupTypes -notcontains "DynamicMembership" }
    

    [int]$GroupCount = $PIMGroups.Count
    [int]$Count = 0

    #Export Eligible Group Members
    [array]$GroupEligibleMembers = $null

    Foreach ($Group in $PIMGroups) {
        
        $Count++
        $Completed = ($Count/$GroupCount) * 100
        Write-Progress -Activity "Getting All Group Eligible Members" -Status "Progress:" -PercentComplete $Completed

        $URI = $GraphURI + "/identityGovernance/privilegedAccess/group/eligibilitySchedules?" + '$filter' + "=groupId eq '" + $group.id + "'"
        Try {

            $Results = Invoke-FGGetRequest -Uri $URI

            Foreach ($Result in $Results) {
                $Row = @{
                    "groupId"    = $Result.groupId
                    "memberId"   = $Result.principalId
                }
                $GroupEligibleMembers += $Row
            }

        }
        Catch {
            #Write-Output $_
            #Write-Output ("Could not get PIM memberships for group " + $Group.displayName) -ForegroundColor Red
        }
    }

    Return $GroupEligibleMembers 
}