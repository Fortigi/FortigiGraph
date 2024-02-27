function Invoke-FGGetRequestToFile {
    Param
    (
        [Parameter(Mandatory = $true)]
        [string]$URI,
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    If (!($Global:AccessToken)) {
        Throw "No Access Token found. Please run Get-AccessToken or Get-AccessTokenInteractive before running this function."
    }
    Else {
        $AccessToken = $Global:AccessToken
    }
    
    If ($Global:DebugMode) {
        If ($Global:DebugMode.Contains('G')) {
            Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++ Debug Message ++++++++++++++++++++++++++++++++++++++++++++++++++++++++" -ForegroundColor Blue
            Write-Host "Invoke-FGGetRequest" -ForegroundColor Blue
            Write-Host $URI -ForegroundColor Blue
        }
    }

    #Check if Access token is expired, if so get new one.
    $TokenIsStillValid = Confirm-FGAccessTokenValidity
    if (!($TokenIsStillValid)) {
        
        If ($Global:DebugMode) {
            If ($Global:DebugMode.Contains('G')) {
                Write-Host "Access Token Expired, getting new one" -ForegroundColor Blue
            }
        }
    
        If ($global:ClientSecret) {
            Get-FGAccessToken -ClientID $Global:ClientID -TenantId $Global:TenantId -ClientSecret $global:ClientSecret
        }
        Elseif ($global:RefreshToken) {
            Get-FGAccessTokenWithRefreshToken -ClientID $Global:ClientID -TenantId $Global:TenantId -RefreshToken $global:RefreshToken
        } 
        Else {
            Throw "Access Token expired."   
        }
    
    }

    $ReturnValue = $Null
    Try {
        #Run request
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
        $ReturnValue = $Result
    }

    #Add results to file
    $ReturnValue | ConvertTo-Json -Depth 10 | Out-File $File -Force

    #By default you only get 100 results... its paged
    While ($Result.'@odata.nextLink') {
        Try {
            $Result = Invoke-RestMethod -Method Get -Uri $Result.'@odata.nextLink' -Headers @{"Authorization" = "Bearer $AccessToken" }
        }
        Catch {
            Throw $_
        }

        #Most get requests will return results in .value but not all.. grr... watch out.. having the propery .value doesn't mean it has a value
        if ($Result.PSobject.Properties.name -match "value") {
            $ReturnValue = $Result.value
        }
        else {
            $ReturnValue = $Result
        }

        #Add results to file, this will add a seperate JSON to the file.. breaking the JSON format
        $ReturnValue | ConvertTo-Json -Depth 10 | Out-File $File -Append
        
    }

    #We now have a file with multiple jsons not a single one. We need to make it a single JSON again.
    $FileObject = Get-Item -Path $File
    $FilePath = $FileObject.Directory.FullName
    Rename-Item -Path $File -NewName "Input.json"
    
    # Define the input and output file paths
    $InputFilePath = $FilePath + "\Input.json"
    $OutputFilePath = $File

    # Create a StreamReader to read the input file
    $Reader = [System.IO.StreamReader]::new($InputFilePath)

    # Create a StreamWriter to write to the output file
    $Writer = [System.IO.StreamWriter]::new($OutputFilePath)

    # Read the first line from the file
    $PreviousLine = $Reader.ReadLine()

    # Write the first line to the output file
    $Writer.WriteLine($PreviousLine)

    # Read the next line from the file
    $PreviousLine = $Reader.ReadLine()

    # Read subsequent lines and check for consecutive lines containing ']' and '['
    while (-not $Reader.EndOfStream) {
        # Read the next line
        $CurrentLine = $Reader.ReadLine()

        # Check if the current line and the previous line contain ']' and '[' respectively
        if ($PreviousLine -eq ']' -and $CurrentLine -eq '[') {
            # Skip writing both lines since they match the condition
            # Read the next line and update the previous line
            $Writer.WriteLine(',')
            $PreviousLine = $Reader.ReadLine()
        }
        else {
            # Write the previous line to the output file
            $Writer.WriteLine($PreviousLine)
            # Update the previous line with the current line
            $PreviousLine = $CurrentLine
        }
    }

    # Write the last line if it doesn't match the condition
    $Writer.WriteLine($PreviousLine)

    # Close the StreamReader and StreamWriter
    $Reader.Close()
    $Writer.Close() 

    Remove-Item $InputFilePath -Force

}