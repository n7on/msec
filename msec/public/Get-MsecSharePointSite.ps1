function Get-MsecSharePointSite {
    <#
    .SYNOPSIS
        Every SharePoint site in the tenant, classified - the inventory to run a site access
        review against.

    .DESCRIPTION
        THE SITE INVENTORY, AS THE APP. What this does NOT carry is the pair of settings that
        actually decide whether an external share succeeds - the site's own sharing level and
        its own domain allow-list. Those are tenant-admin properties, unreadable at any
        permission this module is willing to hold, and they live in
        Get-MsecSharePointSiteSharing, which signs in as a human instead.

        SO A PERMISSIVE READING HERE SETTLES NOTHING ABOUT SHARING. Site settings combine with
        the tenant's as an INTERSECTION - a site can be stricter but never broader - and two
        lists that disagree leave a site unable to share with anybody. Measured on one
        investigation: the tenant allowed one domain, the site allowed three different ones,
        the intersection was empty, and every external share failed with a domain error while
        every value available here read as permissive.

    .PARAMETER IncludeAppContainer
        Include Loop and other app-created storage containers.

    .PARAMETER IncludePersonal
        Include OneDrive personal sites. Note these do not appear in the search Graph uses here
        anyway on most tenants; the switch exists so the exclusion is explicit rather than
        accidental.

    .PARAMETER All
        Include everything, classified but unfiltered.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecSharePointSite

    .EXAMPLE
        # The access review: every real site, and who owns it.
        Get-MsecSharePointSite | ForEach-Object {
            Get-MsecSharePointSiteUser -Url $_.WebUrl
        }

    .EXAMPLE
        # What the tenant actually holds, before deciding what to review.
        Get-MsecSharePointSite -All | Group-Object SiteType | Sort-Object Count -Descending

    .PARAMETER CreatedSince
        Only sites created on or after this date.

        THE POINT IS A WORKLIST, NOT AN ANSWER. Self-service site creation means new sites
        arrive with the tenant's default sharing level and no review; this narrows 149 sites to
        the few worth checking - measured, 10 in 180 days. The sharing level itself still has
        to be read in the SharePoint admin centre, for the reason in the description.

        FILTERS ON CREATION, NOT LAST MODIFIED. "What appeared recently" and "what changed
        recently" are different questions and this answers the first. A site with no
        createdDateTime is included and warned about rather than dropped, because absent is not
        the same as old.

    .PARAMETER IncludeSettings
        Fetch each site's own properties - sharing-link policy, sensitivity label, restricted
        access control, lock state. ONE EXTRA REQUEST PER SITE, which is why it is opt-in;
        measured on one tenant, 149 sites.

        IT DOES NOT INCLUDE THE SITE'S SHARING LEVEL OR ITS DOMAIN LIST - those are in
        Get-MsecSharePointSiteSharing, and reading these as though they answered the same
        question is the mistake this paragraph exists to prevent. ShareByEmailEnabled in
        particular is NOT the sharing mode: measured, it was True on a site where external
        sharing was completely blocked. Settings is $null when a site could not be read, never
        a blank object.

    .OUTPUTS
        PSCustomObject per site, PSTypeName 'MsecSharePointSite'.

    .NOTES
        Runs as the msec app throughout - both the site list and -IncludeSettings. Needs
        Connect-Msec and Sites.Read.All on MICROSOFT GRAPH, which is a different permission
        from the identically-named one on the SharePoint service principal. Both are granted by
        New-MsecApp -Workload SharePoint and do different jobs: the Graph one enumerates sites,
        the SharePoint one reads what is inside them.

        Get-MsecSharePointSiteSharing is the one that needs a human.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $IncludeAppContainer,
        [switch] $IncludePersonal,
        [switch] $All,

        # ONE EXTRA REQUEST PER SITE, which is why it is opt-in - measured, 149 sites.
        [switch] $IncludeSettings,

        # FILTERS ON CREATION, NOT ON LAST CHANGE - see the help.
        [datetime] $CreatedSince
    )

    Assert-MsecSession

    $sites = @()
    try {
        # search=* is the documented way to enumerate every site an app can see. The plain
        # /sites collection returns a different and less complete set.
        $sites = @(Invoke-MsecGraphRequest -All -Path '/v1.0/sites?search=*')
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '403|Forbidden') {
            throw "Forbidden enumerating sites. The msec app needs 'Sites.Read.All' on MICROSOFT GRAPH - note this is NOT the same permission as Sites.Read.All on the SharePoint service principal, and having one does not grant the other. Run New-MsecApp -Workload SharePoint. Original error: $detail"
        }
        throw
    }

    if (-not $sites.Count) {
        Write-Warning 'No sites returned. Check that Sites.Read.All is granted on Microsoft Graph and consented.'
        return
    }

    foreach ($site in $sites) {
        $webUrl = [string] $site.webUrl

        $siteType =
            if ($webUrl -match '(?i)-my\.sharepoint\.[a-z.]+/personal/') { 'Personal' }
            elseif ($webUrl -match '(?i)/contentstorage/')               { 'AppContainer' }
            elseif ($webUrl -match '(?i)/(sites|teams)/')                { 'SiteCollection' }
            elseif ($site.root)                                          { 'Root' }
            else                                                         { 'Other' }

        if (-not $All) {
            if ($siteType -eq 'AppContainer' -and -not $IncludeAppContainer) { continue }
            if ($siteType -eq 'Personal' -and -not $IncludePersonal) { continue }
        }

        # A site with no createdDateTime is NOT silently dropped by a date filter - absent is
        # not "old", and a site nobody can date is exactly the one worth looking at.
        if ($PSBoundParameters.ContainsKey('CreatedSince')) {
            if (-not $site.createdDateTime) {
                Write-Warning "$webUrl has no createdDateTime; included rather than filtered out."
            }
            elseif ([datetime] $site.createdDateTime -lt $CreatedSince) { continue }
        }

        # PER-SITE PROPERTIES COST A CALL EACH, and the token audience is the site's own host.
        # WHAT THIS CANNOT SHOW is the sharing level and the domain list - tenant-admin
        # properties, in Get-MsecSharePointSiteSharing.
        $settings = $null
        if ($IncludeSettings) {
            try {
                $token = Get-MsecAccessToken -Resource "https://$($site.siteCollection.hostname)"
                $r = Invoke-MsecRetryableRequest -What 'SharePoint' -RequestArgs @{
                    Uri     = "$webUrl/_api/site"
                    Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json;odata=nometadata' }
                    ErrorAction = 'Stop' }
                $settings = [PSCustomObject]@{
                    ShareByEmailEnabled            = [bool] $r.ShareByEmailEnabled
                    ShareByLinkEnabled             = [bool] $r.ShareByLinkEnabled
                    DisableCompanyWideSharingLinks = [bool] $r.DisableCompanyWideSharingLinks
                    ExternalSharingTipsEnabled     = [bool] $r.ExternalSharingTipsEnabled
                    RestrictedAccessControl        = [bool] $r.IsRestrictedAccessControlPolicyEnforcedOnSite
                    SensitivityLabelId             = $(if ($r.SensitivityLabelId -and "$($r.SensitivityLabelId)" -ne '00000000-0000-0000-0000-000000000000') { [string] $r.SensitivityLabelId } else { $null })
                    Classification                 = $(if ($r.Classification) { [string] $r.Classification } else { $null })
                    LockIssue                      = $(if ($r.LockIssue) { [string] $r.LockIssue } else { $null })
                    ReadOnly                       = [bool] $r.ReadOnly
                    GroupId                        = $(if ("$($r.GroupId)" -ne '00000000-0000-0000-0000-000000000000') { [string] $r.GroupId } else { $null })
                }
            }
            catch {
                # $null, never a blank object - "could not read" must not look like "all off".
                Write-Warning "Could not read settings for $webUrl : $(($_.Exception.Message -split [char]10)[0])"
            }
        }

        [PSCustomObject]@{
            PSTypeName       = 'MsecSharePointSite'
            DisplayName      = $site.displayName
            SiteType         = $siteType
            WebUrl           = $webUrl
            Name             = $site.name
            Description      = $site.description
            CreatedDateTime  = $site.createdDateTime
            LastModifiedDateTime = $site.lastModifiedDateTime
            Hostname         = $site.siteCollection.hostname
            Id               = $site.id
            Settings         = $settings
        }
    }
}
