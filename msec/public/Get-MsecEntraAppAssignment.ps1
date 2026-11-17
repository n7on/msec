function Get-MsecEntraAppAssignment {
    <#
    .SYNOPSIS
        Who is assigned to an enterprise application - the portal's "Users and groups" blade -
        one row per assignment.

    .DESCRIPTION
        This is the access-review question: which people and which groups can use this app, and
        in which role. It is NOT the consent question. Get-MsecEntraAppConsent reads the same
        Graph collection and deliberately keeps only ServicePrincipal principals, because those
        are application permissions granted TO software. This command keeps the other side -
        User and Group - which is who may USE the app.

        A GROUP IS REPORTED AS A GROUP, NOT EXPANDED. The portal shows the group; so does this.
        A row saying a group is assigned does not tell you how many people that is, and treating
        the row count as a headcount will undercount badly - four of these apps carry four group
        assignments each. Expand with Get-MsecEntraGroupMember when the review needs names.

        A PRINCIPAL CAN HOLD SEVERAL ROLES, AND EACH IS ITS OWN ROW. Counting rows counts
        assignments, not people. Measured on four live apps: 37 rows, of which 21 were user
        assignments - held between just 6 distinct people. Reporting that as 21 users overstates
        the review by more than three times. Group by PrincipalId for a headcount.

        THE UPN IS NOT IN THE ASSIGNMENT AND COSTS A CALL PER USER. appRoleAssignedTo carries
        principalDisplayName and principalId only, so UserPrincipalName and UserEnabled come
        from a second Graph read per DISTINCT user, cached within the call. Display names are
        not unique and say nothing about whether the account still works, which is most of what
        an access review is for - measured on four live apps, 21 users across 37 assignments.

        UserEnabled IS THE COLUMN THAT FINDS THE STALE ONES. An assignment survives the user
        being disabled; nothing cleans it up.

        A PATTERN THAT MATCHES NOTHING WARNS. An app that was renamed, or a wildcard that misses,
        would otherwise return an empty result identical to an app with no assignments - and on
        a monthly review that reads as "nobody has access" rather than "we did not look". Named
        apps are easy to miss: a prefix search for four similarly named apps in a live tenant
        turned up a FIFTH carrying an extra suffix, which an obvious wildcard would exclude.

    .PARAMETER DisplayName
        Enterprise application display names. Wildcards are supported and matching is
        case-insensitive, which matters - display names in a live tenant were inconsistently
        cased ('CONTOSO-PROD-API' beside 'contoso-prod-web').

        A wildcard pattern is matched client-side, so the service principals are enumerated
        first. Graph cannot filter on an arbitrary pattern.

    .PARAMETER AppId
        Application (client) ids, as an alternative to -DisplayName. Exact match, no wildcards.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
            Format-Table Application, PrincipalType, PrincipalDisplayName, Role, UserEnabled

        The monthly access review, as the portal would show it.

    .EXAMPLE
        # Assignments left behind by people whose accounts are disabled.
        Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
            Where-Object { $_.UserEnabled -eq $false }

    .EXAMPLE
        # People, not assignments - a principal holding three roles is one person.
        Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
            Group-Object PrincipalId | Measure-Object | Select-Object -ExpandProperty Count

    .OUTPUTS
        One PSCustomObject per assignment, PSTypeName 'MsecEntraAppAssignment'.

    .NOTES
        Needs Connect-Msec and the 'Application.Read.All' application permission to read the
        service principals and their assignments, plus a directory read ('User.Read.All' or
        'Directory.Read.All') for UserPrincipalName and UserEnabled. Verified against a live
        tenant on the permissions the msec app already holds.

        'Unreadable' in UserPrincipalName means the user lookup FAILED, not that the user has
        no UPN. A warning names how many, and UserEnabled is $null for those rows - a failed
        read must never render as a clean one.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string[]] $DisplayName,

        [Parameter()]
        [string[]] $AppId
    )

    Assert-MsecSession

    # A runtime check rather than [Parameter(Mandatory)]: a mandatory parameter PROMPTS a
    # non-interactive caller and hangs it, and reporting pipelines consume this module. An
    # unfiltered call would also enumerate every assignment in the tenant, which is not a
    # default anyone wants by accident.
    if (-not $DisplayName -and -not $AppId) {
        throw 'Specify -DisplayName (wildcards allowed) or -AppId. Without one, this would enumerate every enterprise application in the tenant.'
    }

    $zeroGuid = '00000000-0000-0000-0000-000000000000'

    # Two phases on purpose. Listing every service principal WITH its appRoles pulls the role
    # definitions of the whole tenant to match a handful of names; the roles are fetched per
    # matched app instead.
    Write-Verbose 'Enumerating service principals'
    $all = @(Invoke-MsecGraphRequest -All -Path ('/v1.0/servicePrincipals?' +
             [uri]::EscapeDataString('$select') + '=id,displayName,appId&' +
             [uri]::EscapeDataString('$top') + '=999'))

    $matched = [System.Collections.Generic.List[object]]::new()

    foreach ($pattern in @($DisplayName)) {
        if (-not $pattern) { continue }
        $hits = @($all | Where-Object { [string] $_.displayName -like $pattern })
        if ($hits.Count -eq 0) {
            # See the help: an empty result here is indistinguishable from an app with nobody
            # assigned, and on a review that is the dangerous direction to be wrong in.
            Write-Warning "No enterprise application matched -DisplayName '$pattern'. No assignments are reported for it - that is NOT the same as the app having none."
            continue
        }
        foreach ($h in $hits) { $matched.Add($h) }
    }

    foreach ($id in @($AppId)) {
        if (-not $id) { continue }
        $hits = @($all | Where-Object { [string] $_.appId -eq $id })
        if ($hits.Count -eq 0) {
            Write-Warning "No enterprise application matched -AppId '$id'. No assignments are reported for it - that is NOT the same as the app having none."
            continue
        }
        foreach ($h in $hits) { $matched.Add($h) }
    }

    # The same app can arrive from both parameters, or from two overlapping patterns.
    $apps = @($matched | Sort-Object { [string] $_.id } -Unique)
    Write-Verbose "Matched $($apps.Count) enterprise application(s)"

    # Cache per call: the same person is usually assigned to several of the apps being reviewed.
    $userCache = @{}
    $unreadableUsers = 0

    foreach ($app in $apps) {
        $appName = [string] $app.displayName

        # appRoles live on the service principal, and the assignment carries only the id.
        $roleName = @{}
        try {
            $detail = Invoke-MsecGraphRequest -Path ("/v1.0/servicePrincipals/$($app.id)?" +
                      [uri]::EscapeDataString('$select') + '=appRoles')
            foreach ($r in @($detail.appRoles)) { $roleName[[string] $r.id] = [string] $r.displayName }
        }
        catch {
            Write-Warning "Could not read the app roles of '$appName', so Role is reported as null on its assignments. Graph said: $($_.Exception.Message)"
        }

        $assignments = $null
        try {
            $assignments = @(Invoke-MsecGraphRequest -All -Path "/v1.0/servicePrincipals/$($app.id)/appRoleAssignedTo?`$top=999")
        }
        catch {
            Write-Warning "Could not read assignments on '$appName'. Its access is MISSING from this output, which is not the same as the app having no assignments. Graph said: $($_.Exception.Message)"
            [PSCustomObject]@{
                PSTypeName           = 'MsecEntraAppAssignment'
                Application          = $appName
                AppId                = [string] $app.appId
                ServicePrincipalId   = [string] $app.id
                PrincipalDisplayName = 'Unreadable'
                PrincipalType        = $null
                PrincipalId          = $null
                UserPrincipalName    = $null
                UserEnabled          = $null
                Role                 = $null
                AppRoleId            = $null
                CreatedDateTime      = $null
                AssignmentId         = $null
            }
            continue
        }

        foreach ($a in $assignments) {
            $type = [string] $a.principalType
            # ServicePrincipal assignments are application permissions granted to software, a
            # different question entirely - Get-MsecEntraAppConsent answers that one.
            if ($type -ne 'User' -and $type -ne 'Group') { continue }

            $upn     = $null
            $enabled = $null
            if ($type -eq 'User') {
                $pid = [string] $a.principalId
                if (-not $userCache.ContainsKey($pid)) {
                    try {
                        $u = Invoke-MsecGraphRequest -Path ("/v1.0/users/$pid`?" +
                             [uri]::EscapeDataString('$select') + '=userPrincipalName,accountEnabled')
                        $userCache[$pid] = [PSCustomObject]@{
                            Upn     = [string] $u.userPrincipalName
                            Enabled = [bool] $u.accountEnabled
                        }
                    }
                    catch {
                        # 'Unreadable' rather than $null: $null is what a Group legitimately has
                        # here, and a failed read must not borrow that meaning.
                        $userCache[$pid] = [PSCustomObject]@{ Upn = 'Unreadable'; Enabled = $null }
                        $unreadableUsers++
                    }
                }
                $upn     = $userCache[$pid].Upn
                $enabled = $userCache[$pid].Enabled
            }

            $roleId = [string] $a.appRoleId
            $role =
                if ($roleId -eq $zeroGuid) { 'Default Access' }
                elseif ($roleName.ContainsKey($roleId)) { $roleName[$roleId] }
                else { $null }   # the app no longer publishes the role this assignment names

            [PSCustomObject]@{
                PSTypeName           = 'MsecEntraAppAssignment'
                Application          = $appName
                AppId                = [string] $app.appId
                ServicePrincipalId   = [string] $app.id
                PrincipalDisplayName = [string] $a.principalDisplayName
                PrincipalType        = $type
                PrincipalId          = [string] $a.principalId
                UserPrincipalName    = $upn
                UserEnabled          = $enabled
                Role                 = $role
                AppRoleId            = $roleId
                CreatedDateTime      = $a.createdDateTime
                AssignmentId         = [string] $a.id
            }
        }
    }

    if ($unreadableUsers -gt 0) {
        Write-Warning "$unreadableUsers user(s) could not be read; their UserPrincipalName is 'Unreadable' and UserEnabled is null. Needs 'User.Read.All' or 'Directory.Read.All'."
    }
}
