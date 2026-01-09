function Get-FGGroupEligibleMemberAll {
    [alias("Get-GroupEligibleMemberAll")]

    # Query eligibility schedules directly - this is the correct way to identify PIM-enabled groups
    # Note: isAssignableToRole and PIM-enabled are INDEPENDENT properties since January 2023
    # Any group (except dynamic) can be PIM-enabled, not just role-assignable groups
    # See: https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/concept-pim-for-groups

    $GraphURI = 'https://graph.microsoft.com/beta'

    Write-Progress -Activity "Getting All Group Eligible Members" -Status "Querying eligibility schedules..." -PercentComplete 0

    # Query ALL eligibility schedules at once - much more efficient than group-by-group
    # This returns only groups that are actually PIM-enabled (have eligible members)
    $URI = $GraphURI + "/identityGovernance/privilegedAccess/group/eligibilitySchedules"

    Try {
        $Results = Invoke-FGGetRequest -Uri $URI

        Write-Progress -Activity "Getting All Group Eligible Members" -Status "Processing results..." -PercentComplete 50

        #Export Eligible Group Members
        [array]$GroupEligibleMembers = @()

        Foreach ($Result in $Results) {
            $Row = @{
                "groupId"    = $Result.groupId
                "memberId"   = $Result.principalId
            }
            $GroupEligibleMembers += $Row
        }

        Write-Progress -Activity "Getting All Group Eligible Members" -Completed

        Return $GroupEligibleMembers
    }
    Catch {
        Write-Progress -Activity "Getting All Group Eligible Members" -Completed
        Write-Error "Failed to retrieve eligible group members: $_"
        Return $null
    }
}