function Get-MsecDefenderAlert {
    <#
    .SYNOPSIS
        One row per Defender XDR alert across every workload - endpoint, Office 365,
        identity, cloud apps and DLP - with the incident it belongs to.

    .DESCRIPTION
        Alerts are the detections; incidents are the groupings Defender builds from them.
        Get-MsecDefenderIncident answers "what is being investigated"; this answers "what
        actually fired", which is the level at which a noisy detector or an unworked queue
        becomes visible.

        SERVICESOURCE IS OFTEN 'unknownFutureValue', AND THAT IS THE API, NOT THE DATA. Graph
        returns that placeholder for a source the API version does not have a name for yet.
        Measured on a live tenant, 231 of 569 alerts in ninety days - 40% - came back that
        way. It is reported verbatim rather than guessed at or folded into 'other', because
        the alternative is inventing a source attribution that Microsoft did not make.
        ProductName and DetectionSource are carried alongside and are often populated when
        ServiceSource is not.

        STATUS VOCABULARY DIFFERS FROM INCIDENTS. An alert is 'new', 'inProgress' or
        'resolved'; an incident is 'active', 'inProgress', 'resolved' or 'redirected'. An
        alert is never 'active'. Filtering both with the same string finds nothing in one of
        them, silently.

        RESOLVEDAYS IS $null WHILE AN ALERT IS OPEN, never 0 - the same reasoning as the
        incident command. Here it is computed from ResolvedUtc, which Graph populates
        properly, rather than inferred from the last update.

        EVIDENCE IS NOT FLATTENED. Every alert carries an evidence array - devices, users,
        files, IP addresses, mailboxes - with a different shape per entity type. Flattening it
        would either lose most of it or produce a column set that changes per row, so the
        count is reported and the array stays on Raw.evidence for anything that needs it.

    .PARAMETER Days
        How far back to look at CREATION time. Default 30.

    .PARAMETER Severity
        Only these severities: informational, low, medium, high.

    .PARAMETER Status
        Only these statuses: new, inProgress, resolved.

    .PARAMETER ServiceSource
        Only alerts from these workloads, matched case-insensitively against ServiceSource -
        e.g. microsoftDefenderForEndpoint, microsoftDefenderForOffice365, dataLossPrevention.

    .PARAMETER UpdatedWithin
        Alerts last TOUCHED within this many days, whatever their age. Use this for triage
        history: -Days finds alerts RAISED in a window, so an alert raised a year ago and
        worked last week is absent from it at every value short of 365. Replaces the
        created-date filter rather than narrowing it.

    .PARAMETER Classification
        The recorded triage verdict. 'unknown' is what an untouched alert carries, so
        -Classification unknown selects the UNtriaged set.

    .PARAMETER Determination
        The recorded cause behind the classification, e.g. notMalicious, securityTesting,
        malware. 'unknown' means nobody recorded one.

    .PARAMETER TriagedBy
        Matches assignedTo. NOT always a person - 'Suppression rule' and
        'MdcAlertsResourceProvider' appear here too, and neither is a human verdict. Name the
        analysts explicitly when the output is going to be learned from.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecDefenderAlert -Days 90 -Severity high | Sort-Object CreatedUtc -Descending

    .EXAMPLE
        # The unworked queue: high-severity alerts nobody has picked up.
        Get-MsecDefenderAlert -Days 90 -Severity high -Status new |
            Format-Table CreatedUtc, Title, ServiceSource, IncidentId

    .EXAMPLE
        # Which detectors produce the most noise.
        Get-MsecDefenderAlert -Days 90 | Group-Object Title |
            Sort-Object Count -Descending | Select-Object -First 15

    .OUTPUTS
        One PSCustomObject per alert, PSTypeName 'MsecDefenderAlert'.

    .NOTES
        Needs Connect-Msec. Documented as 'SecurityAlert.Read.All'; measured on a live tenant
        the endpoint also answers for an app holding SecurityIncident.Read.All and
        SecurityEvents.Read.All, both of which New-MsecApp grants - so it works today without
        an extra consent. If a tenant answers 403, that permission is the one to add.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateRange(1, 365)]
        [int] $Days = 30,

        # FILTERS ON WHEN THE ALERT WAS LAST TOUCHED, NOT WHEN IT WAS RAISED, and the two
        # answer different questions. -Days finds alerts RAISED in a window; an alert raised a
        # year ago and triaged last week is not in that result at any -Days value short of 365.
        # Asking "what has been worked recently" with -Days therefore returns a confident,
        # wrong answer - which is how a tenant with 507 classified alerts was first read as
        # having almost none. Use this for triage history; use -Days for alert volume.
        [ValidateRange(1, 365)]
        [int] $UpdatedWithin,

        # NO DATE FILTER AT ALL, for the question "what is open, however old". -Days and
        # -UpdatedWithin both cap at 365, so neither can answer it, and reaching for a large
        # -Days is not the same thing: an item older than the cap is invisible rather than
        # merely old. That gap is how a backlog gets reported as empty.
        #
        # The result is still bounded - by Graph's own retention on these endpoints, not by
        # anything chosen here - so "any age" means "as far back as the service will answer".
        [Parameter()]
        [switch] $AnyAge,

        [ValidateSet('informational', 'low', 'medium', 'high')]
        [string[]] $Severity,

        # NOT the incident vocabulary - see the note in the description.
        [ValidateSet('new', 'inProgress', 'resolved')]
        [string[]] $Status,

        [string[]] $ServiceSource,

        # The triage verdict someone recorded. 'unknown' is the value an untouched alert
        # carries, so -Classification unknown is the UNtriaged set rather than a missing one.
        [ValidateSet('unknown', 'falsePositive', 'truePositive', 'informationalExpectedActivity')]
        [string[]] $Classification,

        [ValidateSet('unknown', 'apt', 'malware', 'securityPersonnel', 'securityTesting',
                     'unwantedSoftware', 'other', 'multiStagedAttack', 'compromisedAccount',
                     'phishing', 'maliciousUserActivity', 'notMalicious',
                     'lineOfBusinessApplication', 'confirmedActivity')]
        [string[]] $Determination,

        # Who the alert is assigned to. Note that this is NOT always a person: measured on a
        # live tenant, 'Suppression rule' and 'MdcAlertsResourceProvider' appear here on
        # hundreds of alerts, and treating those as human verdicts would mean learning from a
        # suppression rule rather than from an analyst.
        [string[]] $TriagedBy
    )

    Assert-MsecSession

    # -UpdatedWithin REPLACES the created-date filter rather than narrowing it. Sending both
    # would ask for alerts raised AND touched in the window, which silently drops every old
    # alert worked recently - the exact set -UpdatedWithin exists to find.
    if ($AnyAge) {
        $dateFilter = $null
    }
    elseif ($PSBoundParameters.ContainsKey('UpdatedWithin')) {
        $sinceStr = (Get-Date).ToUniversalTime().AddDays(-$UpdatedWithin).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $dateFilter = "lastUpdateDateTime ge $sinceStr"
    }
    else {
        $startStr = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $dateFilter = "createdDateTime ge $startStr"
    }

    try {
        $path = if ($dateFilter) { "/v1.0/security/alerts_v2?`$filter=$dateFilter" } else { '/v1.0/security/alerts_v2' }
        $alerts = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /security/alerts_v2. The msec app needs the 'SecurityAlert.Read.All' application permission (admin consent required). Original error: $($_.Exception.Message)"
        }
        throw
    }

    $parse = {
        param($value)
        if ($value) { [datetime]::Parse($value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } else { $null }
    }

    # Evidence is polymorphic - device, user, ip, file, mailbox, url, process, each with its
    # own fields - so it is flattened to one readable identifier per item. The full objects
    # stay on Raw: this is for reading and for handing to something that has to reason about
    # the alert, not a replacement for the detail.
    $describe = {
        param($e)
        $kind = ([string]$e.'@odata.type') -replace '#microsoft\.graph\.security\.', '' -replace 'Evidence$', ''
        $who  = @(
            $e.deviceDnsName, $e.hostName, $e.userPrincipalName,
            $e.userAccount.userPrincipalName, $e.userAccount.accountName,
            $e.ipAddress, $e.fileDetails.fileName, $e.url,
            $e.primaryAddress, $e.imageFile.fileName, $e.appId
        ) | Where-Object { $_ } | Select-Object -First 1
        $verdict = [string]$e.verdict
        $text = if ($who) { "$kind`: $who" } else { $kind }
        if ($verdict -and $verdict -ne 'unknown') { "$text ($verdict)" } else { $text }
    }

    foreach ($a in $alerts) {
        if ($Severity       -and [string]$a.severity       -notin $Severity) { continue }
        if ($Status         -and [string]$a.status         -notin $Status)   { continue }
        if ($ServiceSource  -and [string]$a.serviceSource  -notin $ServiceSource) { continue }
        if ($Classification -and [string]$a.classification -notin $Classification) { continue }
        if ($Determination  -and [string]$a.determination  -notin $Determination) { continue }
        if ($TriagedBy      -and [string]$a.assignedTo     -notin $TriagedBy) { continue }

        $created  = & $parse $a.createdDateTime
        $resolved = & $parse $a.resolvedDateTime

        [PSCustomObject]@{
            PSTypeName        = 'MsecDefenderAlert'
            Id                = [string] $a.id
            # The alert's id in the product that raised it. For endpoint alerts this is the key
            # into the Defender for Endpoint API, which is the only place a comment can be
            # written - Graph has no writable comment on an alert. See Set-MsecDefenderAlert.
            ProviderAlertId   = [string] $a.providerAlertId
            Title             = [string] $a.title
            Severity          = [string] $a.severity
            Status            = [string] $a.status
            Category          = [string] $a.category
            # 'unknownFutureValue' is Graph's placeholder, not a workload - see the help.
            ServiceSource     = [string] $a.serviceSource
            DetectionSource   = [string] $a.detectionSource
            ProductName       = [string] $a.productName
            IncidentId        = [string] $a.incidentId
            AssignedTo        = [string] $a.assignedTo
            Classification    = [string] $a.classification
            Determination     = [string] $a.determination
            CreatedUtc        = $created
            FirstActivityUtc  = & $parse $a.firstActivityDateTime
            LastActivityUtc   = & $parse $a.lastActivityDateTime
            ResolvedUtc       = $resolved
            # $null while open, never 0.
            ResolveDays       = if ($created -and $resolved) { [math]::Round(($resolved - $created).TotalDays, 1) } else { $null }
            # Counted, not flattened - the shape differs per entity type. Raw.evidence has it.
            EvidenceCount     = @($a.evidence).Count
            # Readable entities - 'Device: vie0172 (suspicious)', 'User: alex@contoso.com'.
            Evidence          = @(foreach ($e in @($a.evidence)) { & $describe $e })
            MitreTechniques   = (@($a.mitreTechniques) -join '; ')
            ThreatDisplayName = [string] $a.threatDisplayName
            AlertWebUrl       = [string] $a.alertWebUrl
            Raw               = $a
        }
    }
}
