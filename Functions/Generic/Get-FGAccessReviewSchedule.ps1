function Get-FGAccessReviewSchedule {
    [alias("Get-AccessReviewSchedule")]
    [cmdletbinding()]
    Param()
        
    $URI = 'https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions'

    $ReturnValue = Invoke-FGGetRequest -URi $URI
    return $ReturnValue
}