function Get-MsecEntraPimActivation {
    <#
    .SYNOPSIS
        Privileged Identity Management activity from the directory audit log - who activated
        which privileged role, for how long, with what justification, and whether MFA was used.

    .DESCRIPTION
        The record of privileged access actually being USED, as opposed to who holds it.
        Get-MsecEntraRoleHolder answers "who could be an administrator"; this answers "who was
        one, when, and why".

        ACTIVATION IS NOT THE ONLY THING HERE. loggedByService 'PIM' covers the whole lifecycle:
        activations and their expiry, eligible assignments added and removed, role settings
        changed, and PIM's own alerts being resolved. AuditType says which. -ActivationsOnly
        narrows to activations when that is the question, and the rest is left in by default
        because "someone changed a PIM role setting" belongs in the same timeline as "someone
        activated the role it governs".

        MFA IS $null WHEN IT WAS NOT RECORDED, NEVER $false. IsAuthenticatedWithMfa is present
        on activation records and absent on most others. Defaulting the absence to false would
        report every role-setting change as an unauthenticated action, and would bury the
        finding that actually matters - an activation that genuinely carried no MFA - in noise
        that is merely unrecorded. Filtering with -WithoutMfa therefore matches $false only.

        BOTH PIM SCOPES ARE RETURNED. Entra directory roles and Azure resource roles both log
        here, distinguished by Category: 'RoleManagement' is the directory, 'ResourceManagement'
        is Azure RBAC. Measured on one tenant over 30 days: 62 directory activations and 54
        Azure resource activations - dropping either would halve the picture, so Scope is a
        column rather than a filter applied silently.

        JUSTIFICATION IS FREE TEXT AND MAY BE ABSENT. Where PIM does not require one, the field
        is simply missing, which is not the same as a user declining to give one - the role
        setting decides. Read an empty Justification alongside Get-MsecEntraPimPolicy, which
        says whether that role demanded it.

        THE WINDOW IS THE AUDIT LOG'S, NOT PIM'S. Directory audit retention is 30 days on Entra
        ID P1/P2 and 7 days without, so -Days is capped at 30 and a tenant without P1 will
        return less than asked for without saying so - that limit is the tenant's licence, not
        this command.

    .PARAMETER Days
        How far back to look. Default 7, maximum 30 - the directory audit retention ceiling.

    .PARAMETER ActivationsOnly
        Only role activations, excluding expiry, eligibility changes and setting changes.

    .PARAMETER WithoutMfa
        Only records where MFA was explicitly NOT used. Records that never carried the field
        are excluded - see the description.

    .PARAMETER NoJustification
        Only records with no justification text.

    .PARAMETER Role
        Limit to one or more role display names. Case-insensitive, matched as a substring so
        'Administrator' catches every administrator role.

    .EXAMPLE
        Get-MsecEntraPimActivation -Days 30 -ActivationsOnly |
            Group-Object Actor, Role | Sort-Object Count -Descending

        Who activates what, and how often.

    .EXAMPLE
        Get-MsecEntraPimActivation -Days 30 -ActivationsOnly -WithoutMfa

        Privileged roles activated without multifactor authentication. An empty result is a
        good answer and worth reporting as one.

    .EXAMPLE
        Get-MsecEntraPimActivation -Days 30 -ActivationsOnly -Role 'Global Administrator' |
            Select-Object ActivityDateTime, Actor, Justification, DurationHours, IpAddress

        Every Global Administrator activation, with the reason given.

    .EXAMPLE
        Get-MsecEntraPimActivation -Days 30 | Where-Object AuditType -eq 'ResolveAlert'

        PIM's own alerts being resolved - the only trace of them that reaches any log, since
        PIM alerts do not flow to Defender XDR or Sentinel.

    .OUTPUTS
        PSCustomObject per audit record, PSTypeName 'MsecEntraPimActivation'.

    .NOTES
        Needs 'AuditLog.Read.All', which the msec app already holds. Pairs with
        Get-MsecEntraPimPolicy (what activation demands) and Get-MsecEntraRoleHolder (who holds
        the role at all).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 7,

        [switch]   $ActivationsOnly,
        [switch]   $WithoutMfa,
        [switch]   $NoJustification,
        [string[]] $Role
    )

    Assert-MsecSession

    $since = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $path  = "/v1.0/auditLogs/directoryAudits?`$filter=loggedByService eq 'PIM' and activityDateTime ge $since"

    $records = $null
    try { $records = @(Invoke-MsecGraphRequest -Path $path -All) }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden reading the directory audit log. The msec app needs 'AuditLog.Read.All' (admin consent required). Original error: $($_.Exception.Message)"
        }
        throw
    }

    foreach ($r in $records) {
        # additionalDetails is a key/value list, not an object - the useful fields all live
        # here and none of them are top-level.
        $detail = @{}
        foreach ($d in @($r.additionalDetails)) {
            if ($d.key) { $detail[[string]$d.key] = [string]$d.value }
        }

        $auditType = $detail['AuditType']
        if ($ActivationsOnly -and $auditType -ne 'ActivateRole') { continue }

        # The first target resource is the role; the rest are tenant and principal shells.
        $roleName = @($r.targetResources | ForEach-Object { [string]$_.displayName } | Where-Object { $_ }) |
                    Select-Object -First 1

        if ($Role) {
            $match = $false
            foreach ($want in $Role) { if ($roleName -and $roleName -like "*$want*") { $match = $true; break } }
            if (-not $match) { continue }
        }

        # $null, NOT $false, when the field is absent. An absent value means "not recorded on
        # this kind of record", and reporting that as "no MFA" would bury the real finding.
        $mfa = if ($detail.ContainsKey('IsAuthenticatedWithMfa')) {
                   $detail['IsAuthenticatedWithMfa'] -in @('True', 'true', '1')
               } else { $null }
        if ($WithoutMfa -and $mfa -ne $false) { continue }

        $justification = if ($detail['Justification']) { $detail['Justification'] } else { $null }
        if ($NoJustification -and $justification) { continue }

        $start  = $null; $expiry = $null
        $parsed = [datetime]::MinValue
        if ($detail['StartTime']      -and [datetime]::TryParse($detail['StartTime'],      [ref] $parsed)) { $start  = $parsed }
        $parsed = [datetime]::MinValue
        if ($detail['ExpirationTime'] -and [datetime]::TryParse($detail['ExpirationTime'], [ref] $parsed)) { $expiry = $parsed }

        # $null rather than 0 where either end is missing: an activation whose window could not
        # be read is not an activation that lasted no time.
        $duration = if ($start -and $expiry) { [math]::Round(($expiry - $start).TotalHours, 1) } else { $null }

        [PSCustomObject]@{
            PSTypeName        = 'MsecEntraPimActivation'
            ActivityDateTime  = if ($r.activityDateTime) { [datetime]$r.activityDateTime } else { $null }
            Activity          = [string]$r.activityDisplayName
            # ActivateRole, ResolveAlert, and the eligibility/setting types. The clearest way
            # to tell one kind of PIM record from another.
            AuditType         = $auditType
            # RoleManagement = Entra directory roles. ResourceManagement = Azure RBAC.
            Scope             = [string]$r.category
            Actor             = @($r.initiatedBy.user.userPrincipalName, $r.initiatedBy.app.displayName) |
                                Where-Object { $_ } | Select-Object -First 1
            Role              = $roleName
            Result            = [string]$r.result
            ResultReason      = [string]$r.resultReason
            # Absent where the role never demanded one - see Get-MsecEntraPimPolicy.
            Justification     = $justification
            StartTime         = $start
            ExpirationTime    = $expiry
            DurationHours     = $duration
            # $null = not recorded on this record type. $false = genuinely no MFA.
            AuthenticatedWithMfa = $mfa
            ApprovalRequired  = if ($detail.ContainsKey('IsActivationRequireApproval')) {
                                    $detail['IsActivationRequireApproval'] -in @('True', 'true', '1')
                                } else { $null }
            IpAddress         = $detail['ipaddr']
            UserAgent         = $detail['UserAgent']
            RoleTemplateId    = $detail['TemplateId']
            CorrelationId     = [string]$r.correlationId
        }
    }
}
