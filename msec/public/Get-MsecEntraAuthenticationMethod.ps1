function Get-MsecEntraAuthenticationMethod {
    <#
    .SYNOPSIS
        Which authentication methods the tenant permits, who they are available to, and which of
        them are phishing-resistant - what "require MFA" actually means here.

    .DESCRIPTION
        Every MFA requirement in the tenant - Conditional Access, PIM activation, step-up on a
        privileged role - resolves to "satisfy one of the enabled methods". This says what that
        set is. A tenant can require MFA everywhere and still accept a code sent by email.

        STATE ALONE IS MISLEADING AND THIS IS THE COMMAND'S MAIN POINT. A method reads 'enabled'
        while being scoped to a single group, so it is enabled for the tenant and available to
        almost nobody. Measured on one tenant: Fido2 showed state 'enabled' with includeTargets
        of exactly one group - the emergency-access accounts, two people - while SMS, Voice and
        Email were enabled for all users. Reporting the state column alone would have described
        that tenant as having FIDO2.

        AvailableToAllUsers is therefore the column to read: true only when the method is enabled
        AND includes the built-in 'all_users' target. IncludeTarget and ExcludeTarget carry the
        detail, resolved to group names.

        NOT EVERY ENABLED METHOD CAN SATISFY MFA. Email OTP is usable for B2B guest redemption
        and self-service password reset, not as a second factor for a member account; QR code
        PIN and Temporary Access Pass are onboarding and recovery credentials. The command
        reports what the tenant permits, which is a wider set than what satisfies an MFA grant.
        Treat -PhishableOnly as "enabled and not phishing-resistant", not as "will satisfy a
        Conditional Access MFA control".

        PHISHING RESISTANCE IS MICROSOFT'S CLASSIFICATION, NOT A JUDGEMENT MADE HERE. Microsoft
        documents FIDO2/passkeys, Windows Hello for Business and certificate-based
        authentication as phishing-resistant; everything else - SMS, voice, email, software OATH
        and Authenticator push - is not. IsPhishingResistant reports that mapping and nothing
        more. A false there is not an accusation that the method is broken; it means a
        credential-phishing or SIM-swap attack can satisfy it.

        A DISABLED METHOD IS STILL RETURNED, with State 'disabled'. Dropping it would make "we
        considered this and turned it off" indistinguishable from "this does not exist", and the
        disabled list is where TemporaryAccessPass and X509Certificate live - the two a tenant
        hardening its privileged access usually wants to turn ON.

        WINDOWS HELLO FOR BUSINESS IS NOT IN THIS POLICY AND SO IS NOT RETURNED. It is governed
        by device configuration (Intune/group policy), not by the authentication methods policy,
        so the Graph response has no row for it at all. It is also phishing-resistant and, on
        the tenant this was built against, the most widely held strong credential there is - 118
        registrations. Reading this command's output as the complete list of phishing-resistant
        coverage would therefore understate it badly. Pair it with
        Get-MsecEntraMfaRegistration, which reports what users have actually registered.

        A SCOPED METHOD DOES NOT REVOKE EXISTING REGISTRATIONS. Targeting controls who may
        REGISTER a method, not who may use one already held. On the same tenant Fido2 was scoped
        to the break-glass group while 13 users held synced passkeys and 16 held macOS secure
        enclave keys - registered before the scope narrowed, and still usable. So a narrow
        IncludeTarget means "no new enrolments", not "nobody has this".

        Runs as the msec app. Needs 'Policy.Read.All', which the app already holds. Group names
        are resolved with Group.Read.All; where a group cannot be resolved its id is reported
        rather than a blank, because an unnamed target is still a target.

    .PARAMETER EnabledOnly
        Only methods currently enabled.

    .PARAMETER PhishableOnly
        Only enabled methods that are NOT phishing-resistant. Note this is "enabled and not
        phishing-resistant", not "satisfies an MFA grant" - see the description on Email OTP.

    .EXAMPLE
        Get-MsecEntraAuthenticationMethod

        Every method, its state, who it reaches, and whether it resists phishing.

    .EXAMPLE
        Get-MsecEntraAuthenticationMethod -PhishableOnly

        What "require MFA" can actually be satisfied with by someone who has phished a password.

    .EXAMPLE
        Get-MsecEntraAuthenticationMethod | Where-Object { $_.State -eq 'enabled' -and -not $_.AvailableToAllUsers }

        Methods that are on, but reach only a named group - often a pilot that never widened.

    .OUTPUTS
        PSCustomObject per method, PSTypeName 'MsecEntraAuthenticationMethod'.

    .NOTES
        Read-only. Read alongside Get-MsecEntraConditionalAccessPolicy and
        Get-MsecEntraPimPolicy: those say where MFA is demanded, this says what will satisfy it.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $EnabledOnly,
        [switch] $PhishableOnly
    )

    Assert-MsecSession

    try { $policy = Invoke-MsecGraphRequest -Path '/v1.0/policies/authenticationMethodsPolicy' }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden reading the authentication methods policy. The msec app needs 'Policy.Read.All' (admin consent required). Original error: $($_.Exception.Message)"
        }
        throw
    }

    # Microsoft's own classification. Anything not on this list is satisfiable by a
    # credential-phishing or SIM-swap attack, which is the distinction the column exists for.
    $phishingResistant = @('Fido2', 'X509Certificate', 'WindowsHelloForBusiness')

    # Group names are resolved once and cached: several methods target the same groups, and an
    # id in the output helps nobody.
    $groupNames = @{}
    $resolve = {
        param([string] $Id)
        if (-not $Id) { return $null }
        # The built-in sentinel for "everyone" - not a real group, and looking it up 404s.
        if ($Id -eq 'all_users') { return 'All users' }
        if ($groupNames.ContainsKey($Id)) { return $groupNames[$Id] }
        $name = $Id
        try { $name = [string](Invoke-MsecGraphRequest -Path "/v1.0/groups/$Id`?`$select=displayName").displayName }
        catch { Write-Verbose "Could not resolve group $Id" }
        if (-not $name) { $name = $Id }
        $groupNames[$Id] = $name
        $name
    }

    foreach ($c in @($policy.authenticationMethodConfigurations)) {
        $id    = [string]$c.id
        $state = [string]$c.state

        if ($EnabledOnly -and $state -ne 'enabled') { continue }

        $resistant = $id -in $phishingResistant
        if ($PhishableOnly -and ($resistant -or $state -ne 'enabled')) { continue }

        $include = @(foreach ($t in @($c.includeTargets)) { & $resolve ([string]$t.id) })
        $exclude = @(foreach ($t in @($c.excludeTargets)) { & $resolve ([string]$t.id) })

        # The whole point of the command: enabled AND reaching everyone. A method enabled for
        # one pilot group is not a method the tenant has.
        $toAll = ($state -eq 'enabled') -and (@($c.includeTargets | Where-Object { [string]$_.id -eq 'all_users' }).Count -gt 0)

        [PSCustomObject]@{
            PSTypeName          = 'MsecEntraAuthenticationMethod'
            Method              = $id
            State               = $state
            # True only when enabled and targeted at all_users - see the description.
            AvailableToAllUsers = $toAll
            # Microsoft's classification, not a judgement made here.
            IsPhishingResistant = $resistant
            IncludeTarget       = @($include)
            ExcludeTarget       = @($exclude)
            # Registration being self-service matters for the methods that are: a user can
            # add a weak method themselves if it is enabled for them.
            SelfServiceRegistration = if ($null -ne $c.isSelfServiceRegistrationAllowed) { [bool]$c.isSelfServiceRegistrationAllowed } else { $null }
            Raw                 = $c
        }
    }
}
