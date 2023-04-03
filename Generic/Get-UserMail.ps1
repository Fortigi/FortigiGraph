function Get-UserMail {
    [cmdletbinding()]
    Param
    (
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$id,
        [Alias("Folder")]
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$MailFolder
    )

    If ($MailFolder) {
        $MailFolders = Get-UserMailFolder -id $id
        $MailFolderId = ($MailFolders | Where-Object {$_.displayName -eq $MailFolder}).id

        if ($MailFolder) {
            $URI = "https://graph.microsoft.com/beta/users/$id/mailFolders/$MailFolderId/messages"
        }
        else {
            Throw "$MailFolder not found."
        }
    }
    Else {
        $URI = "https://graph.microsoft.com/beta/users/$id/messages"
    }

    $ReturnValue = Invoke-GetRequest -URi $URI
    return $ReturnValue


}