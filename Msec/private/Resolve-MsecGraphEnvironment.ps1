function Resolve-MsecGraphEnvironment {
    <#
    .SYNOPSIS
        The Microsoft.Graph SDK environment name whose Graph endpoint matches the one msec is
        reading, e.g. 'China' for https://microsoftgraph.chinacloudapi.cn.

    .DESCRIPTION
        MATCHED ON THE ENDPOINT, NOT THE NAME. The SDK calls the Chinese cloud 'China' where Az
        calls it 'AzureChinaCloud', so mapping by name would need a lookup table that goes stale
        every time a sovereign cloud is added - and the endpoint is what actually has to agree.

        FALLING BACK TO 'Global' IS A GUESS, AND IT WARNS. Signing in against the wrong cloud
        does not fail at sign-in with a clear message; it fails later as a wall of 401s that
        look like a permission problem, or it fails at the authority with nothing but
        "InteractiveBrowserCredential authentication failed".

    .PARAMETER GraphResource
        The Graph endpoint msec is using. Empty means nothing is known about the cloud - the
        caller has no app session - and 'Global' is returned WITHOUT a warning, because an
        assumption nobody can improve on is not worth a message on every call.

    .OUTPUTS
        One string: a name from Get-MgEnvironment, or 'Global'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $GraphResource
    )

    if ([string]::IsNullOrWhiteSpace($GraphResource)) { return 'Global' }

    try {
        $match = @(Get-MgEnvironment -ErrorAction Stop |
                       Where-Object { $_.GraphEndpoint -and $_.GraphEndpoint.TrimEnd('/') -eq $GraphResource.TrimEnd('/') })
        if ($match.Count -eq 1) { return $match[0].Name }
        if ($match.Count -gt 1) {
            Write-Warning "$($match.Count) Graph SDK environments share the endpoint '$GraphResource'; using '$($match[0].Name)'."
            return $match[0].Name
        }
        Write-Warning "No Microsoft.Graph SDK environment matches the endpoint '$GraphResource'. Falling back to 'Global', which is probably wrong for this cloud."
    }
    catch {
        Write-Warning "Could not list the Graph SDK environments, so 'Global' is assumed: $($_.Exception.Message)"
    }

    return 'Global'
}
