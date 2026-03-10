function Test-FGConnection {
    
    If (!($Global:AccessToken)) {
        return $false
    }
    Else {
        return Confirm-FGAccessTokenValidity
    }
}