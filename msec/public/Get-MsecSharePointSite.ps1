function Get-MsecSharePointSite {
    <#
    .SYNOPSIS
        Every SharePoint site in the tenant, classified - the inventory to run a site access
        review against.

    .DESCRIPTION
        TWO SHARING SETTINGS DECIDE WHETHER AN EXTERNAL SHARE SUCCEEDS, and both need the
        TENANT ADMIN host. A site carries its own sharing level - "Only people in your
        organization" through "Anyone" - and its own domain allow-list, independent of the
        tenant settings Get-MsecSharePointTenantSetting reports. They combine with the tenant's
        as an INTERSECTION, so a site can be stricter but never broader, and two lists that
        disagree leave a site unable to share with anybody. Measured on one investigation: the
        tenant allowed one domain, the site allowed three different ones, the intersection was
        empty, and every external share failed with a domain error.

        THE APP CANNOT READ THEM, AND IS NOT GOING TO BE ABLE TO. Tenant administration needs
        Sites.FullControl.All - write access to every site - which this module deliberately
        does not hold. Verified: the certificate authenticates against the -admin host and then
        fails every admin call with "Attempted to perform an unauthorized operation". So
        -IncludeSharingLevel requires an INTERACTIVE sign-in as somebody holding SharePoint
        Administrator, through Connect-MsecSharePointOnline -Interactive. The capability comes
        from that person's role; the app gains nothing.

        THE BULK CALL LIES ABOUT THE DOMAIN RESTRICTION, which is why reading it is a separate
        switch. Get-PnPTenantSite with no -Identity returns every site in about a second and
        its SharingCapability is correct - but SharingDomainRestrictionMode comes back as
        "None" and the domain list empty for a site that genuinely has one. Measured on the
        same site: bulk said None, -Identity said AllowList with four domains. A report built
        on the bulk result would state confidently that no site restricts by domain.
        -IncludeDomainRestriction therefore queries each site individually - about 0.4s each,
        a minute for 150 sites - and leaves the value $null rather than "None" when a site
        could not be read.

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

    .PARAMETER IncludeSharingLevel
        The site's external sharing level, from the tenant admin API: Disabled,
        ExistingExternalUserSharingOnly, ExternalUserSharingOnly or ExternalUserAndGuestSharing.

        REQUIRES AN INTERACTIVE ADMIN SESSION - see the description - and throws naming how to
        get one rather than returning a quietly empty column. One bulk call for the whole
        tenant, so it is cheap. SharingLevel is $null for anything the admin API does not list,
        such as a subsite.

    .PARAMETER IncludeDomainRestriction
        The site's own domain allow/block list. Implies -IncludeSharingLevel.

        ONE CALL PER SITE, because the bulk result is wrong for this field - see the
        description. About 0.4s per site; roughly a minute for 150. DomainRestriction is $null
        when a site could not be read, never "None", because "None" is exactly the wrong answer
        the cheap path gives.

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

        IT DOES NOT INCLUDE THE SITE'S SHARING LEVEL OR ITS DOMAIN LIST, and reading it as
        though it did is the mistake this paragraph exists to prevent - see the description.
        Settings is $null when the site could not be read, never a blank object.

    .OUTPUTS
        PSCustomObject per site, PSTypeName 'MsecSharePointSite'.

    .NOTES
        Needs Connect-Msec and Sites.Read.All on MICROSOFT GRAPH - which is a different
        permission from the identically-named one on the SharePoint service principal. Both are
        granted by New-MsecApp -Workload SharePoint, and they do different jobs: this one
        enumerates sites, the SharePoint one lets PnP read what is inside them.

        No PnP session is needed here. Get-MsecSharePointSiteUser is what needs that, and it
        connects itself.
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
        [datetime] $CreatedSince,

        # Needs an INTERACTIVE PnP session against the admin host - see the help.
        [switch] $IncludeSharingLevel,

        # Implies -IncludeSharingLevel and costs one call PER SITE - see the help.
        [switch] $IncludeDomainRestriction
    )

    Assert-MsecSession

    # ---- tenant-admin sharing, when asked ------------------------------------------------
    # SharingCapability comes from ONE bulk call. The domain restriction does NOT: see the
    # help - the bulk call reports None for a site that genuinely has a list.
    $sharing = @{}
    if ($IncludeSharingLevel -or $IncludeDomainRestriction) {
        if (-not (Get-Command Get-PnPTenantSite -ErrorAction SilentlyContinue)) {
            throw 'PnP.PowerShell is required for -IncludeSharingLevel. Install with: Install-Module PnP.PowerShell -Scope CurrentUser'
        }
        try { $tenantSites = @(Get-PnPTenantSite -ErrorAction Stop) }
        catch {
            throw ("Could not read tenant site settings: $(($_.Exception.Message -split [char]10)[0]) " +
                   'This needs an INTERACTIVE connection to the admin host, because the app-only ' +
                   'certificate is refused there - tenant administration requires Sites.FullControl.All, ' +
                   'a write permission msec does not hold. Run: Connect-MsecSharePointOnline ' +
                   '-Url https://<tenant>-admin.sharepoint.com -Interactive -ClientId <app>')
        }
        foreach ($t in $tenantSites) { $sharing["$($t.Url)".TrimEnd('/').ToLower()] = $t }
        Write-Verbose "Read sharing level for $($sharing.Count) site(s) from the tenant admin API."
    }

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
        # WHAT THIS CANNOT SHOW is in the help: SharingCapability and the per-site domain list
        # live on the tenant-admin surface and need Sites.FullControl.All, a WRITE permission
        # this module will not hold. Verified: Get-PnPTenantSite against the admin host
        # authenticates and then answers "Attempted to perform an unauthorized operation".
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

        $sharingLevel = $null; $restrictionMode = $null; $allowedDomains = $null; $blockedDomains = $null
        if ($sharing.Count) {
            $t = $sharing["$webUrl".TrimEnd('/').ToLower()]
            if ($t) {
                $sharingLevel = [string] $t.SharingCapability
                if ($IncludeDomainRestriction) {
                    # ONE CALL PER SITE, because the bulk result is WRONG here - see the help.
                    try {
                        $one = Get-PnPTenantSite -Identity $webUrl -ErrorAction Stop
                        $restrictionMode = [string] $one.SharingDomainRestrictionMode
                        $allowedDomains  = @("$($one.SharingAllowedDomainList)" -split '[,\s]+' | Where-Object { $_ })
                        $blockedDomains  = @("$($one.SharingBlockedDomainList)" -split '[,\s]+' | Where-Object { $_ })
                    }
                    catch {
                        # $null, never 'None' - that is the lie the bulk call tells.
                        Write-Warning "Could not read the domain restriction for $webUrl : $(($_.Exception.Message -split [char]10)[0])"
                    }
                }
            }
            else { Write-Verbose "No tenant-admin entry for $webUrl (subsite, or not a site collection)." }
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
            SharingLevel     = $sharingLevel
            DomainRestriction = $restrictionMode
            AllowedDomains   = $allowedDomains
            BlockedDomains   = $blockedDomains
            Settings         = $settings
        }
    }
}
