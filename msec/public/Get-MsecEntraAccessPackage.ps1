function Get-MsecEntraAccessPackage {
    <#
    .SYNOPSIS
        Entra entitlement-management access packages with the policy that governs each one -
        who may request it, whether anyone approves, and whether the access ever ends.

    .DESCRIPTION
        The standing-privilege review for entitlement management. One row per access package per
        assignment policy, because the policy is where the controls live: a package on its own
        says what access exists, and says nothing about who can get it or for how long.

        APPROVAL AND EXPIRY ARE DIFFERENT CONTROLS AND ARE EASILY CONFLATED. Approval governs
        WHO GETS IN. Expiry governs HOW LONG THEY STAY. A package that requires approval and
        never expires is not time-boxed access that someone signed off - it is permanent access
        that someone signed off once. Measured on one tenant: all 77 policies required approval,
        and 69 of them never expired, including 25 packages granting directory administrator
        roles. Reading only the approval column would have called that fully governed.

        'never' IS PRINTED, NOT LEFT BLANK. An empty expiry cell reads as "not configured yet",
        which invites the reader to assume a default applies. noExpiration IS the configuration
        and it means permanent, so it is rendered as a value.

        WHAT A PACKAGE GRANTS IS USUALLY A GROUP, NOT A ROLE. Resource roles come back as
        AadGroup/Member far more often than as a directory role, so the access the package
        confers is whatever that group carries - which the package itself does not state. A
        package named for an administrator role may add the member to a group holding a
        permanent role assignment, an eligible one, or nothing at all. ResourceRole is reported
        as what it is; resolving the group's own privilege is Get-MsecEntraRoleHolder's job, and
        the two are meant to be read together.

        ResourceRole IS A string[] so a caller can test it exactly with -contains. Joining the
        entries into one string would force -like '*Administrator*' on every such query, and a
        substring match happily reports 'Helpdesk Administrator' as a hit for 'Administrator'.

        A PACKAGE WITH NO POLICY STILL APPEARS, with Policy null and the control columns blank.
        Such a package cannot be requested by anyone, so it grants nothing - but dropping it
        from the output would hide a package that exists and could be given a policy tomorrow.

        Runs as the msec app. Needs 'EntitlementManagement.Read.All'; these endpoints also
        answer to the Global Reader directory role, so a tenant where that is held may work
        without the grant - which is a side effect to rely on deliberately, not by accident.

    .PARAMETER NoExpiry
        Only policies whose access never expires.

    .PARAMETER SelfRequestable
        Only policies any member of the directory may request (allowedTargetScope
        'allMemberUsers'), as opposed to a named set of users.

    .PARAMETER NoApproval
        Only policies that grant without anyone approving.

    .PARAMETER Catalog
        Limit to one or more catalogs by display name.

    .EXAMPLE
        Get-MsecEntraAccessPackage -NoExpiry

        Every package whose access, once granted, is permanent.

    .EXAMPLE
        Get-MsecEntraAccessPackage -SelfRequestable -NoApproval

        Access anyone in the directory can give themselves unprompted. An empty result here is
        a good answer and worth stating as one.

    .EXAMPLE
        Get-MsecEntraAccessPackage -NoExpiry |
            Where-Object { $_.Package -match 'Administrator' } |
            Select-Object Catalog, Package, AllowedTargetScope, Approvers

        Permanent administrator access, and who signed it off.

    .EXAMPLE
        Get-MsecEntraAccessPackage | Group-Object ApprovalRequired, Expiration

        The shape of the estate - the combination is the finding, not either column alone.

    .OUTPUTS
        PSCustomObject per package/policy pair, PSTypeName 'MsecEntraAccessPackage'.

    .NOTES
        Read-only. Pairs with Get-MsecEntraRoleHolder: this says what a package grants, that
        says what the granted group actually carries.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch]   $NoExpiry,
        [switch]   $SelfRequestable,
        [switch]   $NoApproval,
        [string[]] $Catalog
    )

    Assert-MsecSession

    $base = '/v1.0/identityGovernance/entitlementManagement'

    $get = {
        param([string] $Path, [string] $What)
        try { @((Invoke-MsecGraphRequest -Path $Path).value) }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw "Forbidden reading $What. The msec app needs 'EntitlementManagement.Read.All' (admin consent required), or the Global Reader directory role. Original error: $($_.Exception.Message)"
            }
            throw
        }
    }

    # $expand=catalog, and there is no separate catalogs call: an accessPackage carries NO
    # catalog id of its own - its properties are id, displayName, uniqueName, description,
    # isHidden, createdDateTime, modifiedDateTime and nothing else - so the expand is the only
    # way to name the catalog, and a lookup table built from /catalogs would have nothing to
    # join on.
    $packages = & $get "$base/accessPackages?`$expand=catalog" 'access packages'
    if (-not $packages.Count) { return }

    # A -Catalog that matches nothing is named along with the catalogues that do exist: an
    # empty table is indistinguishable from a typo otherwise.
    if ($Catalog) {
        $present = @($packages | ForEach-Object { [string]$_.catalog.displayName } | Where-Object { $_ } | Sort-Object -Unique)
        foreach ($c in @($Catalog | Where-Object { $_ -notin $present })) {
            Write-Warning ("No catalog named '{0}'. Present: {1}" -f $c, ($present -join ', '))
        }
    }

    # Policies are fetched once for the whole tenant rather than per package: one call instead
    # of one per package, and the expand gives the package id to group them back by.
    $policies = & $get "$base/assignmentPolicies?`$expand=accessPackage" 'assignment policies'
    $byPackage = @{}
    foreach ($p in $policies) {
        $pid = [string]$p.accessPackage.id
        if (-not $pid) { continue }
        if (-not $byPackage.ContainsKey($pid)) { $byPackage[$pid] = [System.Collections.Generic.List[object]]::new() }
        $byPackage[$pid].Add($p)
    }

    foreach ($pkg in $packages) {
        $pkgId   = [string]$pkg.id
        $catName = [string]$pkg.catalog.displayName

        if ($Catalog -and $catName -notin $Catalog) { continue }

        # What the package actually confers. Failure here is reported per package rather than
        # aborting the inventory - one unreadable package must not hide the other 37.
        # NESTED EXPAND, AND IT IS THE WHOLE POINT. With $expand=role,scope the scope comes back
        # named "Root" on every package - the scope is the extent WITHIN the resource, not the
        # resource - so the output says "Root/Member" for all 38 and names nothing. Only
        # role($expand=resource) reaches the resource itself, which is what a reader needs:
        # "pim-entra-authentication-administrator/Member", not "Root/Member".
        $roles = @()
        try {
            foreach ($rr in @((Invoke-MsecGraphRequest -Path "$base/accessPackages/$pkgId/resourceRoleScopes?`$expand=role(`$expand=resource),scope").value)) {
                $rName    = [string]$rr.role.displayName
                $resource = [string]$rr.role.resource.displayName
                $origin   = [string]$rr.role.originSystem
                $text     = (@($resource, $rName) | Where-Object { $_ }) -join '/'
                if ($origin) { $text = "$text [$origin]" }
                if ($text.Trim()) { $roles += $text }
            }
        }
        catch {
            Write-Warning ("Could not read resource roles for '{0}' - ResourceRole is empty on its rows, which is NOT the same as granting nothing: {1}" -f $pkg.displayName, $_.Exception.Message)
        }

        # A LIST, NOT @($null). Writing `$x = @($null)` looks like a one-element array holding
        # null, but PowerShell unwraps a single-element array on assignment, so $x becomes $null
        # outright - and `foreach ($i in $null)` iterates ZERO times. The effect was that every
        # package without an assignment policy silently vanished from the output: exactly the
        # package worth seeing, because nobody can request it and nobody would notice.
        $pkgPolicies = [System.Collections.Generic.List[object]]::new()
        if ($byPackage.ContainsKey($pkgId)) { $pkgPolicies.AddRange(@($byPackage[$pkgId])) }
        else { $pkgPolicies.Add($null) }

        foreach ($pol in $pkgPolicies) {
            # noExpiration IS the configuration, so it is rendered as a value. A blank here
            # would read as "not set yet" and invite the assumption that a default applies.
            $expiry = if (-not $pol) { $null }
                      elseif ([string]$pol.expiration.type -eq 'noExpiration') { 'never' }
                      elseif ($pol.expiration.duration) { [string]$pol.expiration.duration }
                      elseif ($pol.expiration.endDateTime) { "until $([datetime]$pol.expiration.endDateTime)" }
                      else { [string]$pol.expiration.type }

            $approval = if ($pol) { [bool]$pol.requestApprovalSettings.isApprovalRequiredForAdd } else { $null }

            $approvers = @()
            if ($pol) {
                foreach ($stage in @($pol.requestApprovalSettings.stages)) {
                    foreach ($a in @($stage.primaryApprovers)) {
                        $n = @($a.displayName, $a.userPrincipalName, $a.groupId, $a.roleId) | Where-Object { $_ } | Select-Object -First 1
                        if ($n) { $approvers += [string]$n }
                    }
                }
            }

            if ($NoExpiry        -and $expiry -ne 'never')                              { continue }
            if ($SelfRequestable -and [string]$pol.allowedTargetScope -ne 'allMemberUsers') { continue }
            if ($NoApproval      -and $approval -ne $false)                             { continue }

            [PSCustomObject]@{
                PSTypeName         = 'MsecEntraAccessPackage'
                Catalog            = $catName
                Package            = [string]$pkg.displayName
                Policy             = if ($pol) { [string]$pol.displayName } else { $null }
                # allMemberUsers = anyone in the directory may ask. specificDirectoryUsers = a
                # named set. Blank where the package has no policy and so cannot be requested.
                AllowedTargetScope = if ($pol) { [string]$pol.allowedTargetScope } else { $null }
                # $null, not $false, where there is no policy - nobody can request it, which is
                # not the same as it granting without approval.
                ApprovalRequired   = $approval
                Approvers          = @($approvers | Select-Object -Unique)
                # 'never' is a value. See the description.
                Expiration         = $expiry
                # string[] so -contains tests it exactly.
                ResourceRole       = @($roles)
                IsHidden           = [bool]$pkg.isHidden
                PackageId          = $pkgId
                PolicyId           = if ($pol) { [string]$pol.id } else { $null }
                CreatedUtc         = if ($pkg.createdDateTime) { [datetime]$pkg.createdDateTime } else { $null }
            }
        }
    }
}
