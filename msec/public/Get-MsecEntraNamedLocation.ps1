function Get-MsecEntraNamedLocation {
    <#
    .SYNOPSIS
        Named locations, whether each is marked trusted, and which Conditional Access policies
        actually reference it - the networks the tenant treats as special, and what that buys.

    .DESCRIPTION
        A named location is a set of IP ranges or countries given a name so Conditional Access
        can talk about it. Marking one TRUSTED does two things: it lets a policy exclude it,
        and it lowers the risk Identity Protection assigns to sign-ins from it. Both are
        privileges granted to a network rather than to a person.

        A NAMED LOCATION NO POLICY REFERENCES DOES NOTHING AT ALL, however it is flagged.
        UsedByPolicy lists the policies that name it and IsReferenced says whether any do, so
        a trusted location nobody uses is visibly inert rather than alarming. Measured on one
        tenant: seven locations, six of them trusted, and exactly ONE policy referenced any of
        them - which made six of the seven trust flags decorative.

        AN EXCLUSION IN ONE POLICY IS NOT AN EXEMPTION, because Conditional Access grants are
        ADDITIVE. Every applicable policy must be satisfied, so a policy excluding trusted
        locations only stands that policy down there; another policy covering the same user
        still applies. This is the mistake the ReferencedAs column exists to stop: on the same
        tenant a Microsoft-managed MFA policy excluded AllTrusted and looked like an office-IP
        MFA bypass for four admin accounts, until a second enabled policy was found covering
        all four through a group with no location condition at all. Reading one policy's
        exclusion as an exemption would have reported a hole that was not there.

        'AllTrusted' IS A TOKEN, NOT A LOCATION ID. A policy excluding AllTrusted names no
        location explicitly while applying to every location flagged trusted, so matching
        policies on id alone finds nothing and reports the trusted locations as unreferenced.
        Those policies are resolved against every trusted location and marked AllTrusted in
        ReferencedAs.

        Runs as the msec app. Needs 'Policy.Read.All'.

    .PARAMETER TrustedOnly
        Only locations flagged trusted.

    .PARAMETER UnreferencedOnly
        Only locations no Conditional Access policy references - the ones that currently do
        nothing, whatever they are flagged as.

    .EXAMPLE
        Get-MsecEntraNamedLocation

    .EXAMPLE
        # Trusted, and actually used by a policy - the ones whose trust has an effect.
        Get-MsecEntraNamedLocation -TrustedOnly | Where-Object IsReferenced

    .EXAMPLE
        # What each location covers, expanded.
        Get-MsecEntraNamedLocation | Select-Object DisplayName, IsTrusted -ExpandProperty Ranges

    .OUTPUTS
        PSCustomObject per named location, PSTypeName 'MsecEntraNamedLocation'.

    .NOTES
        Read-only. An IP range is only as trustworthy as the network behind it: office egress
        addresses are shared by every device on that network, guest Wi-Fi included unless it
        egresses separately, so trusting one trusts everything behind it.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $TrustedOnly,
        [switch] $UnreferencedOnly
    )

    Assert-MsecSession

    try {
        $locations = @(Invoke-MsecGraphRequest -All -Path '/v1.0/identity/conditionalAccess/namedLocations')
        $policies  = @(Invoke-MsecGraphRequest -All -Path '/v1.0/identity/conditionalAccess/policies')
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw ("Forbidden reading named locations. The msec app needs 'Policy.Read.All' " +
                   "(admin consent required). Original error: $($_.Exception.Message)")
        }
        throw
    }

    # Built once: for each location id, the policies naming it and how. 'AllTrusted' and 'All'
    # are tokens rather than ids, so they are expanded here - a policy excluding AllTrusted
    # references every trusted location without naming one.
    $refs = @{}
    $addRef = {
        param([string] $LocId, $Policy, [string] $How)
        if (-not $refs.ContainsKey($LocId)) { $refs[$LocId] = [System.Collections.Generic.List[object]]::new() }
        $refs[$LocId].Add([PSCustomObject]@{
            PolicyName = [string]$Policy.displayName
            State      = [string]$Policy.state
            How        = $How
        })
    }

    foreach ($p in $policies) {
        foreach ($pair in @(
            @{ Ids = @($p.conditions.locations.includeLocations); How = 'Include' }
            @{ Ids = @($p.conditions.locations.excludeLocations); How = 'Exclude' }
        )) {
            foreach ($id in $pair.Ids) {
                if (-not $id) { continue }
                if ($id -eq 'AllTrusted') {
                    foreach ($t in @($locations | Where-Object { $_.isTrusted })) {
                        & $addRef ([string]$t.id) $p "$($pair.How):AllTrusted"
                    }
                }
                elseif ($id -eq 'All') {
                    foreach ($t in $locations) { & $addRef ([string]$t.id) $p "$($pair.How):All" }
                }
                else {
                    & $addRef ([string]$id) $p $pair.How
                }
            }
        }
    }

    foreach ($l in $locations) {
        $type = ([string]$l.'@odata.type') -replace '#microsoft\.graph\.', ''
        $isIp = $type -eq 'ipNamedLocation'

        # isTrusted exists only on IP locations. A country location cannot be trusted at all,
        # so $false there is the fact rather than a default standing in for a missing property.
        $trusted = if ($isIp) { [bool]$l.isTrusted } else { $false }
        if ($TrustedOnly -and -not $trusted) { continue }

        $ranges = if ($isIp) {
            @(foreach ($r in @($l.ipRanges)) {
                if ($r.cidrAddress) { [string]$r.cidrAddress } else { [string]$r.'@odata.type' }
            })
        }
        else { @($l.countriesAndRegions) }

        $myRefs = @()
        if ($refs.ContainsKey([string]$l.id)) { $myRefs = @($refs[[string]$l.id]) }

        if ($UnreferencedOnly -and $myRefs.Count -gt 0) { continue }

        [PSCustomObject]@{
            PSTypeName   = 'MsecEntraNamedLocation'
            DisplayName  = [string]$l.displayName
            LocationType = if ($isIp) { 'IP' } else { 'Country' }
            # Trust is a privilege granted to a network: it permits exclusion and lowers the
            # risk Identity Protection assigns to sign-ins from here.
            IsTrusted    = $trusted
            RangeCount   = @($ranges).Count
            Ranges       = @($ranges)
            # False means NO policy names it - the location does nothing, whatever it is
            # flagged as.
            IsReferenced = ($myRefs.Count -gt 0)
            UsedByPolicy = @($myRefs | ForEach-Object { $_.PolicyName })
            # Include/Exclude, and whether it was named directly or caught by AllTrusted/All.
            # An Exclude is NOT an exemption - CA grants are additive. See the description.
            ReferencedAs = @($myRefs | ForEach-Object { "$($_.How) ($($_.State))" })
            IncludeUnknownCountries = if ($isIp) { $null } else { [bool]$l.includeUnknownCountriesAndRegions }
            Id           = [string]$l.id
            Raw          = $l
        }
    }
}
