function Invoke-FGGetRequest {
    [alias("Invoke-GetRequest")]
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
    }

    If ($Global:DebugMode) {
        If ($Global:DebugMode.Contains('G')) {
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Invoke-FGGetRequest" -ForegroundColor Blue
            Write-Host $URI -ForegroundColor Blue
        }
    }

    #Check if Access token is expired, if so get new one.
    Update-FGAccessTokenIfExpired -DebugFlag 'G'

    # Get the current (potentially refreshed) access token
    $AccessToken = $Global:AccessToken

    # Extract resource name from URI for progress display
    $resourceName = "Graph API data"
    if ($URI -match '/([^/\?]+)(\?|$)') {
        $resourceName = $matches[1]
    }

    $ReturnValue = $Null
    $pageCount = 0
    $startTime = Get-Date

    Try {
        #Run request
        $pageCount++
        $Result = Invoke-RestMethod -Method Get -Uri $URI -Headers @{"Authorization" = "Bearer $AccessToken" }
    }
    Catch {
        Throw $_
    }

    #Most get requests will return results in .value but not all.. grr... watch out.. having the propery .value doesn't mean it has a value
    if ($Result.PSobject.Properties.name -match "value") {
        $ReturnValue = $Result.value
    }
    else {
        $ReturnValue += $Result
    }

    # Show progress if there are multiple pages (nextLink exists)
    $showProgress = $Result.'@odata.nextLink'

    #By default you only get 100 results... its paged
    While ($Result.'@odata.nextLink') {
        # Check token validity before fetching next page (token may expire during long pagination)
        Update-FGAccessTokenIfExpired -DebugFlag 'G'
        $AccessToken = $Global:AccessToken

        Try {
            $pageCount++
            $Result = Invoke-RestMethod -Method Get -Uri $Result.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $AccessToken" }
        }
        Catch {
            Throw $_
        }
        $ReturnValue += $Result.value

        # Update progress
        if ($showProgress) {
            $elapsed = (Get-Date) - $startTime
            $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($ReturnValue.Count / $elapsed.TotalSeconds, 1) } else { 0 }
            Write-Progress -Activity "Fetching $resourceName" `
                -Status "Page $pageCount - $($ReturnValue.Count) items ($rate items/sec)" `
                -PercentComplete -1
        }
    }

    # Clear progress if it was shown
    if ($showProgress) {
        Write-Progress -Activity "Fetching $resourceName" -Completed
    }

    return $ReturnValue
}