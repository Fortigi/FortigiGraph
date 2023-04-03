function Get-AccessReviewInstance {
    [cmdletbinding()]
    Param
    (
        [Alias("id")]
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$AccessReviewScheduleId
    )

    $URI = "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$AccessReviewScheduleId/instances"

    
    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue
}