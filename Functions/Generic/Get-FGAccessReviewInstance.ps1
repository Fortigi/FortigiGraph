function Get-FGAccessReviewInstance {
    [alias("Get-AccessReviewInstance")]
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

    
    $ReturnValue = Invoke-FGGetRequest -URi $URI
    return $ReturnValue
}