function Get-ApplicationExtensionProperty {
    [alias("Get-FGApplicationExtensionProperty")]
    [cmdletbinding()]
    Param
    (
        #Graph Requires the Object ID (Not APP ID) of the Application that the Extension Property is connected to.
        [Alias("ObjectId")]
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$id
    )

    If ($id) {
        $URI = 'https://graph.microsoft.com/beta/applications/' + "$($id)" + "/extensionProperties"
    }

    $ReturnValue = Invoke-FGGetRequest -URi $URI
    return $ReturnValue


}