function Get-AccessReviewInstanceDecision {
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AccessReviewScheduleId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AccessReviewInstanceId

    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$AccessReviewScheduleId/instances/$AccessReviewInstanceId/decisions"

    
    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
}