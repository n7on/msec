function Set-MsecSentinelIncident {
    <#
    .SYNOPSIS
        Change a Microsoft Sentinel incident - status, classification, owner or severity -
        including the ones Defender XDR cannot see.

    .DESCRIPTION
        The write half of Get-MsecSentinelIncident. Set-MsecDefenderIncident cannot touch an
        incident whose ProviderName is 'Azure Sentinel', because it never reaches the XDR
        incident API at all.

        THE API HAS NO PATCH, ONLY PUT, AND PUT REPLACES THE RESOURCE. Sending just the fields
        being changed silently discards everything else on the incident - owner, labels,
        description, the original title. So this GETs the incident first and puts the existing
        properties back alongside the change. Any hand-written script that skips the GET is
        quietly destroying data it never read.

        THE ETAG IS CONCURRENCY CONTROL, NOT DECORATION. It is sent as If-Match, so a write
        fails rather than overwriting a change somebody made between the read and the write -
        which, on a shared incident queue, is a thing that happens.

        A CLASSIFICATION NEEDS A REASON, EXCEPT WHEN IT MUST NOT HAVE ONE. BenignPositive,
        TruePositive and FalsePositive each require -ClassificationReason; Undetermined
        requires its absence. Checked here so the failure names the rule, rather than arriving
        as a bare 400 from ARM.

        CLASSIFICATION ONLY APPLIES TO A CLOSED INCIDENT. The API accepts classification
        fields only when status is Closed, so passing -Classification without -Status Closed
        is refused here rather than silently ignored.

        IT RUNS ON THE Az CONTEXT, NOT ON Connect-MsecAdmin - UNLIKE Set-MsecDefenderIncident,
        and that difference is forced rather than chosen. Defender XDR incidents are a Graph
        resource reached with delegated Graph scopes; Sentinel incidents are an ARM resource
        reached with Azure RBAC. An ARM endpoint will not accept a Graph token, so there is no
        version of this command that uses the admin session. Needs Microsoft Sentinel Responder
        on the workspace. The msec app holds Graph permissions and is deliberately not given
        this.

        ACCOUNTABILITY IS THE SAME; THE CEREMONY IS NOT. Both commands write as a named human -
        Sentinel records the change under your own UPN - so "writes belong to a person" still
        holds. What differs is that the Az context is already present and cached, where
        Connect-MsecAdmin wants a browser. That makes this runnable unattended, which is
        genuinely useful and is also the thing to be deliberate about: Azure RBAC tends to be
        STANDING, broader and quieter than a Graph admin consent, so the role on the workspace
        is worth reviewing as carefully as the consent would have been.

        -Confirm IS THE REMAINING CHECKPOINT. ConfirmImpact is High, so an interactive caller
        is asked before every write and an unattended one has to pass -Confirm:$false on
        purpose. That explicit opt-out is what replaces the sign-in prompt - do not scatter it
        through a script to silence the noise.

    .PARAMETER Number
        The incident number as shown in the portal. Resolved to the underlying GUID by reading
        the workspace first.

    .PARAMETER Name
        The incident's GUID, as returned by Get-MsecSentinelIncident. Skips the lookup.

    .PARAMETER WorkspaceName
        The workspace holding the incident. Required - an incident number is only unique
        within one workspace.

    .PARAMETER SubscriptionId
        Subscription to act in. Defaults to the active Az context.

    .PARAMETER ResourceGroupName
        Narrows the workspace search.

    .PARAMETER Status
        New, Active or Closed.

    .PARAMETER Classification
        Why the incident was closed. Requires -Status Closed.

    .PARAMETER ClassificationReason
        Required for BenignPositive, TruePositive and FalsePositive; must be omitted for
        Undetermined.

    .PARAMETER ClassificationComment
        Free text recorded with the closure. Worth writing - it is the only part of a closed
        incident that explains the decision to the next reader.

    .PARAMETER Owner
        UPN to assign. Pass an empty string to unassign.

    .PARAMETER Severity
        High, Medium, Low or Informational.

    .PARAMETER PassThru
        Emit the incident as it stands after the change.

    .EXAMPLE
        Get-MsecSentinelIncident -WorkspaceName contoso-sentinel |
            Where-Object { $_.Status -eq 'New' -and $_.ProviderName -eq 'Azure Sentinel' } |
            Set-MsecSentinelIncident -WorkspaceName contoso-sentinel -Status Closed `
                -Classification BenignPositive -ClassificationReason SuspiciousButExpected `
                -ClassificationComment 'Pre-XDR backlog, reviewed in bulk' -WhatIf

        Dry-run the backlog nobody could close from Defender. Drop -WhatIf to commit.

    .OUTPUTS
        One PSCustomObject per incident changed, with the before and after of each field
        touched. With -PassThru, the full incident instead.

    .NOTES
        Needs Connect-MsecAzure and Microsoft Sentinel Responder on the workspace. Runs as
        YOU, not as the msec app.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ByNumber')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'ByNumber', ValueFromPipelineByPropertyName)]
        [int] $Number,

        [Parameter(Mandatory, ParameterSetName = 'ByName', ValueFromPipelineByPropertyName)]
        [string] $Name,

        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string] $WorkspaceName,

        [string] $SubscriptionId,
        [string] $ResourceGroupName,

        [ValidateSet('New', 'Active', 'Closed')]
        [string] $Status,

        [ValidateSet('BenignPositive', 'TruePositive', 'FalsePositive', 'Undetermined')]
        [string] $Classification,

        [ValidateSet('SuspiciousButExpected', 'SuspiciousActivity', 'IncorrectAlertLogic', 'InaccurateData')]
        [string] $ClassificationReason,

        [string] $ClassificationComment,

        [string] $Owner,

        [ValidateSet('High', 'Medium', 'Low', 'Informational')]
        [string] $Severity,

        [switch] $PassThru
    )

    begin {
        if (-not ($PSBoundParameters.Keys | Where-Object { $_ -in 'Status', 'Classification', 'ClassificationReason', 'ClassificationComment', 'Owner', 'Severity' })) {
            throw 'Nothing to change. Pass at least one of -Status, -Classification, -ClassificationReason, -ClassificationComment, -Owner or -Severity.'
        }
        # See the help: the API's own rules, checked before the call so the error names them.
        if ($Classification -and $Classification -ne 'Undetermined' -and -not $ClassificationReason) {
            throw "-Classification $Classification requires -ClassificationReason. Only 'Undetermined' may be set without one."
        }
        if ($Classification -eq 'Undetermined' -and $ClassificationReason) {
            throw "-Classification Undetermined must NOT carry a -ClassificationReason. Omit it, or choose a different classification."
        }
        if ($Classification -and $Status -and $Status -ne 'Closed') {
            throw "-Classification applies only to a closed incident, but -Status $Status was passed. Use -Status Closed, or drop the classification."
        }
        if ($Classification -and -not $Status) {
            throw '-Classification applies only to a closed incident. Pass -Status Closed as well.'
        }

        $script:SentinelResolved = @{}
    }

    process {
        $key = "$SubscriptionId|$ResourceGroupName|$WorkspaceName"
        if (-not $script:SentinelResolved.ContainsKey($key)) {
            $r = Resolve-MsecSentinelWorkspace -SubscriptionId $SubscriptionId `
                     -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName
            if (-not $r.Workspaces.Count) { throw "Workspace '$WorkspaceName' was not found." }
            if ($r.Workspaces.Count -gt 1) {
                throw ("'$WorkspaceName' matched $($r.Workspaces.Count) workspaces. Pass -ResourceGroupName to disambiguate - " +
                       'writing to the wrong one is not recoverable from here.')
            }
            $script:SentinelResolved[$key] = $r
        }
        $resolved  = $script:SentinelResolved[$key]
        $headers   = $resolved.Headers
        $workspace = $resolved.Workspaces[0]

        $incidentName = $Name
        if ($PSCmdlet.ParameterSetName -eq 'ByNumber') {
            $match = @(Get-MsecSentinelIncident -SubscriptionId $SubscriptionId `
                           -ResourceGroupName $ResourceGroupName -WorkspaceName $WorkspaceName |
                       Where-Object { $_.Number -eq $Number })
            if (-not $match.Count) { throw "No incident numbered $Number in workspace '$WorkspaceName'." }
            $incidentName = $match[0].Name
        }

        $url = "$($workspace.Base)/incidents/$incidentName" + '?api-version=2024-09-01'

        # READ BEFORE WRITE, ALWAYS. PUT replaces - see the help.
        try { $before = Invoke-RestMethod -Headers $headers -Uri $url -ErrorAction Stop }
        catch {
            $detail = "$($_.Exception.Message)"
            if ($detail -match '403|Forbidden') {
                throw ("Forbidden reading incident $incidentName in '$($workspace.Name)'. Writing needs the " +
                       "'Microsoft Sentinel Responder' role on the workspace - Azure RBAC, not Entra. Original error: $detail")
            }
            throw "Could not read incident $incidentName before writing: $detail"
        }

        $p = $before.properties
        $changes = [System.Collections.Generic.List[string]]::new()
        foreach ($field in @(
            @{ Name = 'Status';                Old = $p.status;                New = $Status }
            @{ Name = 'Classification';        Old = $p.classification;        New = $Classification }
            @{ Name = 'ClassificationReason';  Old = $p.classificationReason;  New = $ClassificationReason }
            @{ Name = 'ClassificationComment'; Old = $p.classificationComment; New = $ClassificationComment }
            @{ Name = 'Severity';              Old = $p.severity;              New = $Severity }
        )) {
            if ($PSBoundParameters.ContainsKey($field.Name) -and "$($field.Old)" -ne "$($field.New)") {
                $changes.Add("$($field.Name): '$($field.Old)' -> '$($field.New)'")
            }
        }
        if ($PSBoundParameters.ContainsKey('Owner') -and "$($p.owner.userPrincipalName)" -ne "$Owner") {
            $changes.Add("Owner: '$($p.owner.userPrincipalName)' -> '$Owner'")
        }
        if (-not $changes.Count) {
            Write-Verbose "Incident $($p.incidentNumber) already matches the requested values; nothing sent."
            return
        }

        # EVERY EXISTING PROPERTY CARRIED FORWARD, then the change applied on top.
        $body = @{
            properties = @{
                title                 = $p.title
                description           = $p.description
                severity              = $(if ($PSBoundParameters.ContainsKey('Severity')) { $Severity } else { $p.severity })
                status                = $(if ($PSBoundParameters.ContainsKey('Status'))   { $Status }   else { $p.status })
                firstActivityTimeUtc  = $p.firstActivityTimeUtc
                lastActivityTimeUtc   = $p.lastActivityTimeUtc
                labels                = @($p.labels)
            }
        }
        if ($PSBoundParameters.ContainsKey('Owner')) {
            $body.properties['owner'] = @{ userPrincipalName = $(if ($Owner) { $Owner } else { $null }) }
        }
        elseif ($p.owner) { $body.properties['owner'] = $p.owner }

        $finalStatus = $body.properties['status']
        if ($finalStatus -eq 'Closed') {
            $body.properties['classification']        = $(if ($PSBoundParameters.ContainsKey('Classification')) { $Classification } else { $p.classification })
            $body.properties['classificationComment'] = $(if ($PSBoundParameters.ContainsKey('ClassificationComment')) { $ClassificationComment } else { $p.classificationComment })
            $reason = $(if ($PSBoundParameters.ContainsKey('ClassificationReason')) { $ClassificationReason } else { $p.classificationReason })
            if ($reason -and $body.properties['classification'] -ne 'Undetermined') {
                $body.properties['classificationReason'] = $reason
            }
        }

        $target = "incident $($p.incidentNumber) ('$($p.title)') in $($workspace.Name)"
        if (-not $PSCmdlet.ShouldProcess($target, "Set $($changes -join '; ')")) { return }

        $writeHeaders = $headers.Clone()
        if ($before.etag) { $writeHeaders['If-Match'] = $before.etag }

        try {
            $after = Invoke-RestMethod -Headers $writeHeaders -Method Put -ContentType 'application/json' `
                        -Uri $url -Body ($body | ConvertTo-Json -Depth 8) -ErrorAction Stop
        }
        catch {
            $detail = "$($_.Exception.Message)"
            if ($detail -match '412|PreconditionFailed') {
                throw ("Incident $($p.incidentNumber) changed between the read and the write, so nothing was " +
                       'written - the etag no longer matched. Re-read it and try again; somebody else is working on it.')
            }
            if ($detail -match '403|Forbidden') {
                throw ("Forbidden writing incident $($p.incidentNumber) in '$($workspace.Name)'. This needs the " +
                       "'Microsoft Sentinel Responder' role on the workspace - Azure RBAC, not Entra, so the msec " +
                       "app cannot help. Original error: $detail")
            }
            throw "Could not write incident $($p.incidentNumber): $detail"
        }

        if ($PassThru) {
            Get-MsecSentinelIncident -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName `
                -WorkspaceName $WorkspaceName | Where-Object { $_.Name -eq $incidentName }
            return
        }

        [PSCustomObject]@{
            PSTypeName      = 'MsecSentinelIncidentChange'
            Number          = [int] $p.incidentNumber
            Title           = [string] $p.title
            WorkspaceName   = $workspace.Name
            Changed         = @($changes)
            StatusBefore    = [string] $p.status
            StatusAfter     = [string] $after.properties.status
            ProviderName    = [string] $p.providerName
            Name            = $incidentName
        }
    }
}
