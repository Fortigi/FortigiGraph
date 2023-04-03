function Get-AccessReviewSchedule {
        
    $URI = 'https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions'

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
}