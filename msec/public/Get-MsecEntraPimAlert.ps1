function Get-MsecEntraPimAlert {
    <#
    .SYNOPSIS
        Privileged Identity Management's own security alerts about the tenant's privileged
        access - findings that reach no other product.

    .DESCRIPTION
        PIM scans privileged access and raises its own findings: roles assigned outside PIM, too
        many global administrators, roles that do not require multifactor authentication to
        activate, stale accounts in privileged roles. They are posture findings about
        configuration, not detections of an event.

        THESE ALERTS REACH NEITHER DEFENDER XDR NOR SENTINEL. Verified on one tenant: 333
        Defender XDR alerts over 30 days across Defender for Office 365, Defender for Cloud,
        Sentinel, DLP and Defender for Endpoint, with no PIM product among them; and no row in
        Sentinel's SecurityAlert mentioning PIM at all. There is no connector that brings them.
        The only trace that reaches a log is a single audit record when one is RESOLVED, which
        names the alert after the fact and says nothing about what is active now - so without
        this command, a live PIM alert is visible only to someone opening the PIM blade.

        AN INACTIVE ALERT IS NOT AN ABSENT ONE, which is why every alert definition the tenant
        scans for is returned with IsActive saying where it stands. Returning only the firing
        ones would make "we are not scanning for that" and "that is fine" look identical.

        INCIDENT COUNT IS THE SIZE OF THE FINDING, not its severity. 'Roles are being assigned
        outside Privileged Identity Management' with 104 incidents and with 1 are the same
        alert at the same severity and very different problems.

        THIS IS A BETA GRAPH ENDPOINT. /beta/identityGovernance/roleManagementAlerts has no v1.0
        equivalent at the time of writing, so the shape can change under it. The command reads
        it rather than pretending the data is unavailable, and this note is here so a future
        failure is recognised as an API change rather than a tenant with nothing to report.

        Needs 'RoleManagementAlert.Read.Directory'. Global Reader does NOT cover it - measured:
        the endpoint returns 403 to an app holding Global Reader and 20 other Graph permissions.

    .PARAMETER ActiveOnly
        Only alerts currently firing.

    .PARAMETER IncludeIncidents
        Fetch the incidents behind each alert - the specific roles, and for some alert types the
        specific people. One extra request per alert, so it is a switch rather than the default.
        The incident shape VARIES BY ALERT TYPE: 'Roles don't require MFA for activation' names
        only the role, while 'Eligible administrators aren't activating' names the assignee and
        when they last activated. Common fields are projected; Raw keeps the rest.

    .PARAMETER Scope
        The scope to query. 'DirectoryRole' (default) covers Entra directory roles.

    .EXAMPLE
        Get-MsecEntraPimAlert

        Every PIM alert definition with where it stands, firing or not.

    .EXAMPLE
        Get-MsecEntraPimAlert -ActiveOnly | Sort-Object IncidentCount -Descending

        What PIM currently objects to, biggest first.

    .EXAMPLE
        Get-MsecEntraPimAlert -ActiveOnly |
            Where-Object AlertName -match 'outside'

        Whether roles are being assigned outside PIM - the finding that standing privilege is
        accumulating by a route the activation record never shows.

    .OUTPUTS
        PSCustomObject per alert, PSTypeName 'MsecEntraPimAlert'.

    .NOTES
        Pairs with Get-MsecEntraPimActivation, which shows the alert being resolved but never
        the alert itself.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $ActiveOnly,
        [switch] $IncludeIncidents,

        [Parameter()]
        [ValidateSet('DirectoryRole')]
        [string] $Scope = 'DirectoryRole'
    )

    Assert-MsecSession

    $path = "/beta/identityGovernance/roleManagementAlerts/alerts?`$filter=scopeId eq '/' and scopeType eq '$Scope'&`$expand=alertDefinition"

    $alerts = $null
    try { $alerts = @(Invoke-MsecGraphRequest -Path $path -All) }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden reading PIM alerts. The msec app needs 'RoleManagementAlert.Read.Directory' (admin consent required) - the Global Reader directory role does NOT cover this endpoint. Original error: $($_.Exception.Message)"
        }
        if ($_.Exception.Message -match '404|BadRequest|400') {
            throw "PIM alerts could not be read ($($_.Exception.Message)). This is a BETA Graph endpoint (/beta/identityGovernance/roleManagementAlerts) and its shape can change - treat this as an API change rather than a tenant with no alerts."
        }
        throw
    }

    foreach ($a in $alerts) {
        $def = $a.alertDefinition

        # $null, not 0, where the count is absent: an alert whose size was not reported is not
        # an alert with nothing behind it.
        $incidents = if ($null -ne $a.incidentCount) { [int]$a.incidentCount } else { $null }

        if ($ActiveOnly -and -not $a.isActive) { continue }

        # NEVER SCANNED IS NOT A DATE IN THE YEAR 1. An alert the tenant has not evaluated comes
        # back as 0001-01-01, and comparing against DateTime::MinValue does not catch it -
        # parsing a Z-suffixed sentinel converts to local time, so east of UTC it lands just
        # above MinValue and renders as a real timestamp. The year is what separates them.
        # Observed on 'Potential stale accounts in a privileged role'.
        $scanned = $null
        if ($a.lastScannedDateTime) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse([string]$a.lastScannedDateTime, [ref] $parsed) -and $parsed.Year -gt 1) {
                $scanned = $parsed
            }
        }

        # INCIDENT SHAPE VARIES BY ALERT TYPE, so the projection keeps what is common and Raw
        # keeps everything: noMfaOnRoleActivation carries only the role, while
        # redundantAssignment adds the assignee and when they last activated. Flattening to a
        # single fixed shape would silently drop the half that differs.
        $incidentRows = @()
        if ($IncludeIncidents) {
            try {
                foreach ($i in @(Invoke-MsecGraphRequest -Path "/beta/identityGovernance/roleManagementAlerts/alerts/$($a.id)/alertIncidents" -All)) {
                    $last = $null
                    if ($i.lastActivationDateTime) {
                        $lp = [datetime]::MinValue
                        if ([datetime]::TryParse([string]$i.lastActivationDateTime, [ref] $lp) -and $lp.Year -gt 1) { $last = $lp }
                    }
                    $incidentRows += [PSCustomObject]@{
                        PSTypeName     = 'MsecEntraPimAlertIncident'
                        AlertName      = [string]$def.displayName
                        IncidentType   = ([string]$i.'@odata.type') -replace '^#microsoft\.graph\.', ''
                        Role           = [string]$i.roleDisplayName
                        RoleTemplateId = [string]$i.roleTemplateId
                        Assignee       = [string]$i.assigneeDisplayName
                        AssigneeUpn    = [string]$i.assigneeUserPrincipalName
                        # $null means NEVER ACTIVATED, which is the finding for a redundant
                        # assignment - not a missing value.
                        LastActivation = $last
                        IncidentId     = [string]$i.id
                        Raw            = $i
                    }
                }
            }
            catch {
                Write-Warning ("Could not read incidents for '{0}' - its Incidents list is empty, which is NOT the same as the alert having none: {1}" -f $def.displayName, $_.Exception.Message)
            }
        }

        [PSCustomObject]@{
            PSTypeName       = 'MsecEntraPimAlert'
            AlertName        = [string]$def.displayName
            # False means PIM scanned and found nothing, which is a measurement. It is NOT the
            # same as the alert being switched off - see IsEnabled.
            IsActive         = [bool]$a.isActive
            IncidentCount    = $incidents
            Severity         = [string]$def.severityLevel
            # Whether the tenant scans for this at all. A disabled definition reports
            # IsActive false for the same reason a clean tenant does.
            IsEnabled        = if ($null -ne $def.isConfigurable -and $null -ne $a.alertConfiguration.isEnabled) {
                                   [bool]$a.alertConfiguration.isEnabled
                               } else { $null }
            # $null where the alert has never been scanned - see above.
            LastScannedUtc   = $scanned
            # Populated only with -IncludeIncidents. Empty array otherwise, which is why the
            # switch exists rather than it being inferred from the array being empty.
            Incidents        = @($incidentRows)
            Description      = [string]$def.description
            HowToPrevent     = [string]$def.howToPrevent
            IsRemediatable   = if ($null -ne $def.isRemediatable) { [bool]$def.isRemediatable } else { $null }
            ScopeType        = [string]$a.scopeType
            AlertId          = [string]$a.id
            AlertDefinitionId = [string]$def.id
        }
    }
}
