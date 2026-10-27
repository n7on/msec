function Get-MsecEntraCrossTenantAccess {
    <#
    .SYNOPSIS
        Cross-tenant access settings - which external tenants may collaborate, and which of
        their security claims this tenant accepts in place of its own.

    .DESCRIPTION
        Cross-tenant access decides two things for every external organisation: whether their
        users may be invited in at all, and whether their MFA and device claims are accepted
        here. Both are set once in a place nobody looks at again, and the defaults govern far
        more partners than the explicit entries do.

        AN INHERITED SETTING IS NOT A SETTING OF FALSE, AND THIS IS THE DEFECT THE COMMAND
        EXISTS TO PREVENT. Graph returns inboundTrust as NULL on a partner that has no override
        - it inherits the tenant default - and null renders as blank or False in almost any
        table. If the default later turns MFA trust ON, every one of those partners silently
        follows, while a report built from the raw field still shows them as not trusting.
        TrustsMfa here is the EFFECTIVE value, resolved against the default; IsInherited says
        whether the partner set it or merely follows.

        THE DEFAULT ROW IS RETURNED AS A ROW, not as context for the others. On a measured
        tenant, four partners were configured - all IT suppliers - while the guests that
        actually mattered, 25 from one CRO and 24 from another, had no entry at all and were
        governed entirely by the default. Reading only the partner list describes the
        organisations someone once thought about, not the ones with access.

        TRUSTING MFA CANNOT ADMIT AN UN-AUTHENTICATED USER, which is worth stating because the
        setting is routinely read as a weakening. It accepts an MFA claim the home tenant
        actually issued; where the home tenant performed no MFA there is no claim, and a
        Conditional Access policy requiring MFA still blocks. What it avoids is making someone
        who has already done MFA do it again here - in a tenant where the methods available to
        a guest may well be weaker than the ones they just used.

        Runs as the msec app. Needs 'Policy.Read.All'. Tenant names are resolved through
        findTenantInformationByTenantId, which is unauthenticated tenant metadata; a tenant
        that cannot be resolved reports its id rather than a blank.

    .PARAMETER TrustingMfaOnly
        Only entries whose effective setting accepts the partner's MFA claim.

    .PARAMETER BlockedOnly
        Only entries where inbound B2B collaboration is blocked outright.

    .EXAMPLE
        Get-MsecEntraCrossTenantAccess

        The default row plus every configured partner, with what each one's claims buy them.

    .EXAMPLE
        # Partners that merely follow the default - they move the moment the default moves.
        Get-MsecEntraCrossTenantAccess | Where-Object IsInherited

    .OUTPUTS
        PSCustomObject per scope, PSTypeName 'MsecEntraCrossTenantAccess'.

    .NOTES
        Read-only. Read with Get-MsecEntraGuest: this says which organisations may hold
        accounts here, that says which ones actually do.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $TrustingMfaOnly,
        [switch] $BlockedOnly
    )

    Assert-MsecSession

    try {
        $default  = Invoke-MsecGraphRequest -Path '/v1.0/policies/crossTenantAccessPolicy/default'
        $partners = @(Invoke-MsecGraphRequest -All -Path '/v1.0/policies/crossTenantAccessPolicy/partners')
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw ("Forbidden reading the cross-tenant access policy. The msec app needs " +
                   "'Policy.Read.All' (admin consent required). Original error: $($_.Exception.Message)")
        }
        throw
    }

    # The default's own trust block. Every partner without an override resolves to these.
    $dTrust = $default.inboundTrust
    $dMfa   = [bool]$dTrust.isMfaAccepted
    $dComp  = [bool]$dTrust.isCompliantDeviceAccepted
    $dHybr  = [bool]$dTrust.isHybridAzureADJoinedDeviceAccepted

    $names = @{}
    $resolveName = {
        param([string] $Id)
        if ($names.ContainsKey($Id)) { return $names[$Id] }
        $n = $Id
        try {
            $info = Invoke-MsecGraphRequest -Path "/v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='$Id')"
            if ($info.displayName) { $n = [string]$info.displayName }
        }
        catch { Write-Verbose "Could not resolve tenant $Id" }
        $names[$Id] = $n
        $n
    }

    # accessType is absent on an entry that has never been narrowed, and absent means allowed -
    # the B2B default. Reporting a blank there would read as 'unknown' for the common case.
    $access = {
        param($Block)
        $t = [string]$Block.usersAndGroups.accessType
        if ($t) { $t } else { 'allowed' }
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    $rows.Add([PSCustomObject]@{
        PSTypeName           = 'MsecEntraCrossTenantAccess'
        Scope                = 'Default'
        TenantName           = '(every tenant without its own entry)'
        TenantId             = $null
        InboundB2B           = & $access $default.b2bCollaborationInbound
        OutboundB2B          = & $access $default.b2bCollaborationOutbound
        TrustsMfa            = $dMfa
        TrustsCompliantDevice = $dComp
        TrustsHybridJoin     = $dHybr
        # The default cannot inherit from anything, so this is always false here.
        IsInherited          = $false
        Raw                  = $default
    })

    foreach ($p in $partners) {
        $tid = [string]$p.tenantId

        # NULL MEANS INHERIT, NOT FALSE. Resolving against the default is the whole point.
        $inherited = ($null -eq $p.inboundTrust)
        $mfa  = if ($inherited -or $null -eq $p.inboundTrust.isMfaAccepted) { $dMfa } else { [bool]$p.inboundTrust.isMfaAccepted }
        $comp = if ($inherited -or $null -eq $p.inboundTrust.isCompliantDeviceAccepted) { $dComp } else { [bool]$p.inboundTrust.isCompliantDeviceAccepted }
        $hybr = if ($inherited -or $null -eq $p.inboundTrust.isHybridAzureADJoinedDeviceAccepted) { $dHybr } else { [bool]$p.inboundTrust.isHybridAzureADJoinedDeviceAccepted }

        $rows.Add([PSCustomObject]@{
            PSTypeName           = 'MsecEntraCrossTenantAccess'
            Scope                = 'Partner'
            TenantName           = & $resolveName $tid
            TenantId             = $tid
            InboundB2B           = & $access $p.b2bCollaborationInbound
            OutboundB2B          = & $access $p.b2bCollaborationOutbound
            # Effective, not raw - see the description.
            TrustsMfa            = $mfa
            TrustsCompliantDevice = $comp
            TrustsHybridJoin     = $hybr
            # True means this partner follows the default and will move when it moves.
            IsInherited          = $inherited
            Raw                  = $p
        })
    }

    foreach ($r in $rows) {
        if ($TrustingMfaOnly -and -not $r.TrustsMfa) { continue }
        if ($BlockedOnly -and $r.InboundB2B -ne 'blocked') { continue }
        $r
    }
}
