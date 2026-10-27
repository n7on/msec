function Get-MsecBusinessCentralAccess {
    <#
    .SYNOPSIS
        Who holds which permission set in Business Central, across every environment and
        company - including the Entra applications that Entra alone cannot tell you about.

    .DESCRIPTION
        The access review for the finance system. One row per user per permission set per
        company, with the user's state and licence type alongside, so "who has SUPER" is a
        filter rather than an afternoon in the portal.

        AN ENTRA APPLICATION'S REAL ACCESS IS NOT VISIBLE FROM ENTRA. Service-to-service access
        takes two steps in two systems: an application permission in Entra, and then a
        separate record in Business Central's 'Microsoft Entra applications' page where the app
        is enabled and assigned permission sets. Entra shows only that an app MAY reach
        Business Central; what it can touch is set here. An app holding API.ReadWrite.All might
        carry a trivial permission set, or a broad one, and Get-MsecEntraAppConsent cannot tell
        the two apart. IsApplication marks those principals.

        BLANK COMPANY MEANS EVERY COMPANY, NOT NONE. An assignment with Scope 'System' carries
        an empty company, because it applies across the whole environment. Rendering that as a
        missing value - or filtering it out as incomplete - turns the broadest grant in the
        system into the one that looks like nothing. Company is reported as '(all companies)'
        for exactly that reason.

        A DISABLED USER STILL HAS ASSIGNMENTS, so State travels with every row. A list of SUPER
        holders that does not say which of them are disabled overstates the live exposure, and
        one that silently drops them hides an account that need only be re-enabled.

        userPermissionSets IS NOT USED, DELIBERATELY. It returns HTTP 400 on some environments
        and data on others within the same major version - measured on one tenant: working on
        two environments and failing on three. accessControls answers the same question and
        works everywhere, so the flaky endpoint is avoided rather than wrapped in a retry that
        would quietly return less from some environments than others.

        Runs as the signed-in user - see the note below.

    .PARAMETER Environment
        Limit to named environments. All of them by default.

    .PARAMETER SuperOnly
        Only assignments of SUPER - the permission set the product documents as "This role has
        all permissions."

    .PARAMETER ApplicationsOnly
        Only Entra application principals, not people.

    .PARAMETER IncludeDisabled
        Include assignments held by disabled users. Excluded by default, because a review of
        live access should not be padded with accounts that cannot sign in - they are still
        reachable with -IncludeDisabled, and the count of what was hidden is reported.

    .EXAMPLE
        Get-MsecBusinessCentralAccess -SuperOnly

        Everyone with unrestricted access to the finance system, in every environment.

    .EXAMPLE
        Get-MsecBusinessCentralAccess -SuperOnly |
            Where-Object { $_.AuthenticationEmail -notlike '*@contoso.com' }

        External parties holding unrestricted access - partners, consultants, technicians.

    .EXAMPLE
        Get-MsecBusinessCentralAccess -ApplicationsOnly |
            Select-Object Environment, UserName, RoleId, AppName

        What each service-to-service integration can actually do, which Entra does not show.

    .EXAMPLE
        Get-MsecBusinessCentralAccess | Group-Object Environment, RoleId |
            Sort-Object Count -Descending

        The shape of permission assignment across the estate.

    .OUTPUTS
        PSCustomObject per assignment, PSTypeName 'MsecBusinessCentralAccess'.

    .NOTES
        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP - see Get-MsecBusinessCentralEnvironment
        for why. Needs Connect-AzAccount, not Connect-Msec.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]] $Environment,
        [switch]   $SuperOnly,
        [switch]   $ApplicationsOnly,
        [switch]   $IncludeDisabled
    )

    $ctx = Get-MsecBusinessCentralToken
    $res = $ctx.Resource
    $headers = $ctx.Headers

    try {
        $environments = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
            -Uri "$res/admin/v2.24/applications/businesscentral/environments").value)
    }
    catch {
        $status = if ($_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { $null }
        if ($status -in 401, 403) {
            throw "Business Central admin API returned $status. This command runs as the signed-in user and needs a Business Central or Dynamics 365 administrator role. Original: $($_.Exception.Message)"
        }
        throw "Could not list Business Central environments: $($_.Exception.Message)"
    }

    if ($Environment) {
        $wanted = @($environments | Where-Object { $_.name -in $Environment })
        $missing = @($Environment | Where-Object { $_ -notin @($environments.name) })
        foreach ($m in $missing) {
            Write-Warning ("No environment named '{0}'. Present: {1}" -f $m, (@($environments.name) -join ', '))
        }
        $environments = $wanted
    }

    $hiddenDisabled = 0

    foreach ($e in $environments) {
        $name = [string] $e.name

        $companies = $null
        try {
            $companies = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
                -Uri "$res/v2.0/$name/api/v2.0/companies").value)
        }
        catch {
            # Skipped, not silently empty: an environment that refused enumeration is a gap in
            # the review and the reader has to know which one.
            Write-Warning ("Could not list companies in environment '{0}', so its access is NOT included below: {1}" -f $name, $_.Exception.Message)
            continue
        }
        if (-not $companies.Count) {
            Write-Warning ("Environment '{0}' returned no companies, so no access could be read from it." -f $name)
            continue
        }

        # Both endpoints are routed through a company id but return environment-wide results, so
        # one company is enough. Iterating every company would multiply identical rows.
        $cid = $companies[0].id

        $users = @{}
        try {
            foreach ($u in @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
                -Uri "$res/v2.0/$name/api/microsoft/automation/v2.0/companies($cid)/usersPermissions").value)) {
                $users[[string]$u.userSecurityId] = $u
            }
        }
        catch {
            Write-Warning ("Could not read user detail in '{0}' - State, LicenseType and AuthenticationEmail will be blank on its rows: {1}" -f $name, $_.Exception.Message)
        }

        $controls = $null
        try {
            $controls = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
                -Uri "$res/v2.0/$name/api/microsoft/automation/v2.0/companies($cid)/accessControls").value)
        }
        catch {
            Write-Warning ("Could not read access controls in environment '{0}', so its access is NOT included below: {1}" -f $name, $_.Exception.Message)
            continue
        }

        foreach ($c in $controls) {
            $sid  = [string] $c.userSecurityId
            $user = $users[$sid]

            $state = if ($user) { [string] $user.state } else { $null }
            if (-not $IncludeDisabled -and $state -eq 'Disabled') { $hiddenDisabled++; continue }

            # A non-zero applicationId is an Entra application, not a person.
            $appId = [string] $user.applicationId
            $isApp = [bool]($appId -and $appId -ne '00000000-0000-0000-0000-000000000000')

            if ($ApplicationsOnly -and -not $isApp) { continue }
            if ($SuperOnly -and [string]$c.roleId -ne 'SUPER') { continue }

            # expiryDate of 0001-01-01 is the product's "no expiry", not a date in the past.
            # COMPARING AGAINST DateTime::MinValue DOES NOT CATCH IT: parsing '0001-01-01T00:00:00Z'
            # converts to local time, so in any timezone east of UTC the sentinel comes back as
            # 0001-01-01T00:54:00+00:54 - greater than MinValue, and the guard lets it through as
            # a real expiry in the year 1. The year is what actually distinguishes the two.
            $expiry = $null
            if ($user -and $user.expiryDate) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$user.expiryDate, [ref] $parsed) -and $parsed.Year -gt 1) {
                    $expiry = $parsed
                }
            }

            [PSCustomObject]@{
                PSTypeName         = 'MsecBusinessCentralAccess'
                Environment        = $name
                EnvironmentType    = [string] $e.type
                UserName           = [string] $c.userName
                FullName           = [string] $c.fullName
                AuthenticationEmail = if ($user) { [string] $user.authenticationEmail } else { $null }
                State              = $state
                LicenseType        = [string] $c.userLicenseType
                # SUPER is documented as "This role has all permissions."
                RoleId             = [string] $c.roleId
                RoleName           = [string] $c.roleName
                # Empty means EVERY company, not none - see the description.
                Company            = if ([string]$c.company) { [string] $c.company } else { '(all companies)' }
                Scope              = [string] $c.scope
                IsApplication      = $isApp
                ApplicationId      = if ($isApp) { $appId } else { $null }
                AppName            = [string] $c.appName
                ExpiryDate         = $expiry
                UserSecurityId     = $sid
            }
        }
    }

    if ($hiddenDisabled -gt 0) {
        Write-Warning ("{0} assignment(s) held by disabled users were excluded. They are still assignments - re-enabling the account restores them. Use -IncludeDisabled to see them." -f $hiddenDisabled)
    }
}
