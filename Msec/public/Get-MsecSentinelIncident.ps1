function Get-MsecSentinelIncident {
    <#
    .SYNOPSIS
        One row per Microsoft Sentinel incident, read from the workspace itself rather than
        from Defender XDR - including the ones XDR has never seen.

    .DESCRIPTION
        PROVIDERNAME IS THE WHOLE REASON THIS EXISTS. A Sentinel workspace that was in use
        before it was connected to Defender XDR keeps those older incidents with
        ProviderName 'Azure Sentinel'. They are never synced to XDR, so
        Get-MsecDefenderIncident cannot see them at all - measured on one workspace, 628 of
        3,721 incidents, and 53 of the 248 still open.

        AND THE SecurityIncident TABLE IS NOT A SUBSTITUTE. That table ages out with workspace
        retention - 31 days on the workspace measured - while the incidents themselves live in
        ARM far longer: the oldest OPEN incident found this way was created 21 months earlier.
        So an incident can be simultaneously open, invisible to XDR, and absent from KQL. Both
        of the obvious places to look return nothing, and nothing looks like 'clean'.

        IT PAGES, AND NOT PAGING IS A SILENT TRUNCATION. The API caps a page well below the
        total; the same workspace returned 3,721 incidents over four pages at the largest
        page size, and still had a nextLink after six pages at a smaller one. A single GET
        returns a confident, short, wrong answer.

        ENTITIES COST A POST PER INCIDENT, which is why -IncludeEntities is opt-in. The call
        is POST .../incidents/{name}/entities and it is a READ despite the verb - it changes
        nothing. On a few hundred incidents it roughly doubles the runtime.

        IT RUNS ON THE Az CONTEXT, AS YOU. Sentinel is an Azure resource, so this is Azure RBAC
        rather than Graph: the msec app holds Graph permissions and cannot read this. Needs
        Microsoft Sentinel Reader on the workspace.

    .PARAMETER SubscriptionId
        Subscription to read. Defaults to the active Az context.

    .PARAMETER ResourceGroupName
        Narrows the workspace search.

    .PARAMETER WorkspaceName
        A single workspace. Without it, every Sentinel-onboarded workspace in scope is read.

    .PARAMETER Status
        New, Active or Closed. Filtered server-side. Omit for every status.

    .PARAMETER Days
        Only incidents CREATED in the last N days. Filters on createdTimeUtc, not on last
        modified - 'what was opened recently' and 'what was touched recently' are different
        questions and this answers the first.

    .PARAMETER AnyAge
        Send no date filter at all. The default is also no filter; -AnyAge exists to say so
        explicitly in a script that might otherwise look like it forgot -Days.

    .PARAMETER IncludeEntities
        Fetch the entities for each incident - accounts, IPs, hosts, URLs, cloud applications.
        One extra request per incident; see the description.

    .EXAMPLE
        Get-MsecSentinelIncident -WorkspaceName contoso-sentinel -Status New |
            Group-Object ProviderName

        The split that matters: anything under 'Azure Sentinel' is invisible to
        Get-MsecDefenderIncident and will not be triaged by anyone working from XDR.

    .EXAMPLE
        Get-MsecSentinelIncident -WorkspaceName contoso-sentinel |
            Where-Object { $_.Status -ne 'Closed' -and $_.ProviderName -eq 'Azure Sentinel' } |
            Sort-Object CreatedUtc

        The backlog nobody can see from Defender, oldest first.

    .OUTPUTS
        One PSCustomObject per incident, PSTypeName 'MsecSentinelIncident'. Etag is carried so
        Set-MsecSentinelIncident can write without clobbering a concurrent change. Raw keeps
        the untouched ARM object.

    .NOTES
        Needs Connect-MsecAzure and Microsoft Sentinel Reader on the workspace. Runs as YOU,
        not as the msec app.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $SubscriptionId,
        [string] $ResourceGroupName,
        [string] $WorkspaceName,

        [ValidateSet('New', 'Active', 'Closed')]
        [string] $Status,

        [ValidateRange(1, 3650)]
        [int] $Days,

        [switch] $AnyAge,

        [switch] $IncludeEntities
    )

    if ($Days -and $AnyAge) {
        throw '-Days and -AnyAge contradict each other. -AnyAge means no date filter; omit one.'
    }

    $resolved = Resolve-MsecSentinelWorkspace -SubscriptionId $SubscriptionId `
                    -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
    if (-not $resolved.Workspaces.Count) { return }

    $headers  = $resolved.Headers
    $filters  = [System.Collections.Generic.List[string]]::new()
    if ($Status) { $filters.Add("properties/status eq '$Status'") }
    if ($Days)   {
        $since = [datetime]::UtcNow.AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $filters.Add("properties/createdTimeUtc ge $since")
    }

    $unreadable = 0
    foreach ($workspace in $resolved.Workspaces) {
        $query = "api-version=2024-09-01&`$top=1000"
        if ($filters.Count) { $query += '&$filter=' + [uri]::EscapeDataString(($filters -join ' and ')) }
        $uri = "$($workspace.Base)/incidents?$query"

        $raw = [System.Collections.Generic.List[object]]::new()
        try {
            # PAGED TO THE END. See the help - a single GET truncates silently.
            while ($uri) {
                $page = Invoke-MsecRetryableRequest -What 'Azure Resource Manager' -RequestArgs @{
                    Headers = $headers; Uri = $uri; ErrorAction = 'Stop' }
                foreach ($i in @($page.value)) { $raw.Add($i) }
                $uri = $page.nextLink
            }
        }
        catch {
            $detail = "$($_.Exception.Message)"
            if ($detail -match '403|Forbidden') {
                throw ("Forbidden reading incidents in workspace '$($workspace.Name)'. This needs the " +
                       "'Microsoft Sentinel Reader' role on the workspace, which is Azure RBAC and is NOT " +
                       'granted through Entra - the msec app cannot help here. Original error: ' + $detail)
            }
            # A workspace that is not onboarded to Sentinel 404s on this path. Counted and
            # warned about rather than thrown, so one ordinary log workspace does not stop a
            # subscription-wide read.
            if ($detail -match '404|NotFound') {
                Write-Verbose "Workspace '$($workspace.Name)' has no Sentinel incidents endpoint; not onboarded."
                continue
            }
            $unreadable++
            Write-Warning "Could not read incidents in workspace '$($workspace.Name)': $detail"
            continue
        }

        foreach ($i in $raw) {
            $p = $i.properties
            $entities = $null
            if ($IncludeEntities) {
                try {
                    # POST, and it is a read - the API expresses the expansion as a body.
                    $e = Invoke-MsecRetryableRequest -What 'Azure Resource Manager' -RequestArgs @{
                        Headers = $headers; Method = 'Post'; ContentType = 'application/json'
                        Uri = "$($workspace.Base)/incidents/$($i.name)/entities?api-version=2024-09-01"
                        Body = '{}'; ErrorAction = 'Stop' }
                    $entities = @($e.entities | ForEach-Object {
                        $ep = $_.properties
                        [PSCustomObject]@{
                            Kind  = [string] $_.kind
                            Value = [string] $(
                                if ($ep.accountName)      { "$($ep.accountName)@$($ep.upnSuffix)" }
                                elseif ($ep.address)      { $ep.address }
                                elseif ($ep.hostName)     { $ep.hostName }
                                elseif ($ep.url)          { $ep.url }
                                elseif ($ep.appName)      { $ep.appName }
                                else                      { $ep.friendlyName }
                            )
                        }
                    })
                }
                catch {
                    # $null, not @() - "could not read" must not look like "no entities".
                    Write-Warning "Could not read entities for incident $($p.incidentNumber) in '$($workspace.Name)': $($_.Exception.Message)"
                }
            }

            [PSCustomObject]@{
                PSTypeName             = 'MsecSentinelIncident'
                Number                 = [int] $p.incidentNumber
                Title                  = [string] $p.title
                Severity               = [string] $p.severity
                Status                 = [string] $p.status
                Classification         = $(if ($p.classification) { [string] $p.classification } else { $null })
                ClassificationReason   = $(if ($p.classificationReason) { [string] $p.classificationReason } else { $null })
                ClassificationComment  = $(if ($p.classificationComment) { [string] $p.classificationComment } else { $null })
                # THE FIELD THIS COMMAND EXISTS FOR - see the help.
                ProviderName           = [string] $p.providerName
                Owner                  = $(if ($p.owner.userPrincipalName) { [string] $p.owner.userPrincipalName } else { $null })
                CreatedUtc             = $p.createdTimeUtc
                LastModifiedUtc        = $p.lastModifiedTimeUtc
                AlertCount             = [int] $p.additionalData.alertsCount
                AlertProductNames      = @($p.additionalData.alertProductNames)
                Tactics                = @($p.additionalData.tactics)
                RelatedAnalyticRuleIds = @($p.relatedAnalyticRuleIds)
                IncidentUrl            = [string] $p.incidentUrl
                WorkspaceName          = $workspace.Name
                Name                   = [string] $i.name
                Etag                   = [string] $i.etag
                Entities               = $entities
                Raw                    = $i
            }
        }
    }

    if ($unreadable) {
        Write-Warning "$unreadable workspace(s) could not be read. The result is INCOMPLETE - this is not the same as those workspaces having no incidents."
    }
}
