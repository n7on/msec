function Connect-MsecAdmin {
    <#
    .SYNOPSIS
        Signs in AS YOU, with delegated write scopes, for the commands that change something.
        Read commands keep using the app; this session is only for writes.

    .DESCRIPTION
        THE APP CANNOT DO THIS, ON PURPOSE. Every Graph permission New-MsecApp consents is
        *.Read.All, so the certificate in Key Vault cannot change anything - that is the
        module's central promise and it is enforced by the token, not by naming. Writes
        therefore run as a person instead: attributable to a named account, subject to your
        Conditional Access and MFA, bounded by your own Defender RBAC rather than tenant-wide
        application permissions, and impossible from an unattended pipeline unless somebody
        deliberately sets one up.

        NOT THE -AsCurrentUser PATTERN, AND HERE IS WHY. Connect-MsecTeams borrows the Az
        context's token, which works because Azure PowerShell's first-party app holds the
        scopes those commands need. Measured on a live tenant, its Graph token carries
        Application.ReadWrite.All, Group.ReadWrite.All, Directory.AccessAsUser.All and
        User.Read.All - and nothing for security. There is no SecurityAlert.ReadWrite.All in
        it, so borrowing cannot resolve an alert. This asks for consent properly instead.

        CONSENT REQUESTED IS NOT CONSENT GRANTED. Connect-MgGraph succeeds when a tenant
        declines a scope; the context simply comes back without it, and the first write then
        fails with a 403 that names nothing. Every requested scope is checked against what was
        actually granted, and a missing one is reported by name here rather than discovered
        later.

        THE SESSION PERSISTS, SO IT CAN BE REUSED. -ContextScope defaults to CurrentUser,
        which caches a refresh token, so signing in once covers later shells and later
        switches instead of opening a browser each time. A named context exists to collect
        connections and reuse the ones already authenticated; a write session that evaporated
        with the shell could never be part of that.

        PERSISTING THE CREDENTIAL IS NOT THE SAME AS SHARING THE POINTER, and conflating the
        two is the mistake worth avoiding here. The cached token says "this person has signed
        in on this machine". It does NOT decide which tenant any given shell is aimed at -
        Get-MgContext is per process, and this command always names the tenant and the account
        explicitly, so two shells can hold write sessions in two different tenants at the same
        time and neither can re-point the other. The thing that genuinely did leak between
        shells was the AZURE context pointer, which Set-MsecContext and Connect-MsecAzure keep
        process-scoped for exactly that reason.

        WHAT IT DOES COST: until the token expires or you run Disconnect-MgGraph, any process
        running as you can obtain a delegated token carrying your write scopes, with no prompt.
        The module's position is still that writes belong to a person - that is why they are
        delegated rather than application permissions, and why every change is attributable to
        a named account - but "somebody signed in on this machine" is a weaker claim than "a
        person is at the keyboard now". -ContextScope Process declines the trade, at the price
        of signing in again on every switch.

        IT SIGNS IN TO THE CLOUD Connect-Msec IS READING, not always the commercial one.
        Connect-MgGraph defaults to Global, whose authority is login.microsoftonline.com, and a
        sovereign tenant id does not resolve there - against a China tenant the sign-in is
        rejected before any consent screen and the only message is
        "InteractiveBrowserCredential authentication failed:" with nothing after the colon. The
        cloud is taken from the read session's Graph endpoint, so run Connect-Msec first. With
        no read session the commercial cloud is assumed, which is right for most people and
        wrong in exactly the case that is hardest to diagnose.

        IT WILL REFUSE A DIFFERENT TENANT FROM THE ONE YOU ARE READING. If Connect-Msec holds
        a session, this must sign in to the same tenant. Reading one tenant and writing to
        another is the kind of mistake that is obvious afterwards and invisible at the time.

    .PARAMETER Account
        The account that must end up signed in. Cannot select one - Connect-MgGraph has no
        such control and the browser reuses whichever identity it remembers - but a sign-in
        that lands on a different account is REFUSED and the session closed, rather than
        leaving you writing as somebody else.

        Without it, a mismatch against the account this tenant used last time is a warning.

    .PARAMETER ContextScope
        Where the token lives. 'CurrentUser' (default) caches a refresh token so later shells
        and later context switches reuse it instead of prompting. 'Process' keeps it in this
        shell only - Connect-MgGraph's own default - and then every switch that moves a write
        session signs in again.

        Neither value decides which tenant a shell is aimed at; see the description.

    .PARAMETER Scope
        Delegated scopes to request. DEFAULTS TO EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED,
        so a bare Connect-MsecAdmin makes all of them work and nobody has to know which consent
        belongs to which command. Pass it explicitly for a least-privilege session covering only
        what you intend to do.

    .PARAMETER TenantId
        Tenant to sign in to. Defaults to the tenant Connect-Msec is using, which is almost
        always what you want.

    .PARAMETER PassThru
        Emit the Graph context as well as the summary.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec      # reads, as the app
        Connect-MsecAdmin                        # writes, as you

    .EXAMPLE
        # Only what this session needs.
        Connect-MsecAdmin -Scope SecurityAlert.ReadWrite.All

    .OUTPUTS
        One PSCustomObject describing the session: Account, TenantId, GrantedScope.

    .NOTES
        Needs the Microsoft.Graph.Authentication module, which is NOT a dependency of msec -
        it is only required by the write commands.

        Disconnect with Disconnect-MgGraph. Connect-Msec and this session are independent;
        disconnecting one leaves the other alone.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # THE DEFAULT IS EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED, so one connection makes
        # all of them work. The alternative - defaulting to a subset - means knowing which scope
        # a given command wants before you can run it, and discovering you guessed wrong only
        # when the write fails. Nobody should have to remember that resolving an incident and
        # creating a detection rule are different consents.
        #
        # ADDING A WRITE COMMAND MEANS ADDING ITS SCOPE HERE. Pass -Scope explicitly for a
        # least-privilege session covering only what you intend to do.
        #
        #   SecurityAlert.ReadWrite.All      Set-MsecDefenderAlert
        #   SecurityIncident.ReadWrite.All   Set-MsecDefenderIncident
        #   CustomDetection.ReadWrite.All    New-MsecDefenderDetectionRule
        [string[]] $Scope = @(
            'SecurityIncident.ReadWrite.All'
            'SecurityAlert.ReadWrite.All'
            'CustomDetection.ReadWrite.All'
        ),

        [string] $TenantId,

        # THE IDENTITY THAT MUST END UP SIGNED IN. Connect-MgGraph has no way to FORCE an
        # account - the browser reuses whichever it remembers - so this cannot select one.
        # What it can do is refuse when the wrong one arrives, which is the whole value: with
        # two tenants and two identities the wrong account is picked silently, and the
        # consequence surfaces much later either as a write into the tenant you did not mean
        # or as AADSTS500213, a cross-tenant policy error that names nothing about accounts.
        #
        # Defaults to the account recorded for this tenant by the last successful sign-in, so
        # after the first time it checks itself.
        [string] $Account,

        # WHERE THE TOKEN LIVES, AND IT DEFAULTS TO PERSISTING so a saved context can reuse a
        # session that is already authenticated rather than prompting on every switch.
        #
        # PERSISTING THE CREDENTIAL IS NOT SHARING THE POINTER. Get-MgContext is per process
        # and this command always names the tenant and account explicitly, so two shells can
        # hold write sessions in two different tenants at once and neither re-points the
        # other. The pointer that genuinely leaked between shells was the AZURE context, and
        # that is process-scoped in Set-MsecContext and Connect-MsecAzure.
        #
        # It is still a real widening: until the token expires, any process running as this
        # user can obtain a delegated token with these write scopes without a prompt.
        # 'Process' declines that, and pays for it with a browser on every switch.
        [ValidateSet('Process', 'CurrentUser')]
        [string] $ContextScope = 'CurrentUser',

        [switch] $PassThru
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is required for Connect-MsecAdmin. Install with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    # Default to the tenant being READ, so a write cannot land somewhere else by accident.
    if (-not $TenantId -and $script:MsecSession -and $script:MsecSession.TenantId) {
        $TenantId = $script:MsecSession.TenantId
    }

    $connectArgs = @{ Scopes = $Scope; NoWelcome = $true; ErrorAction = 'Stop'
                      ContextScope = $ContextScope }
    if ($TenantId) { $connectArgs['TenantId'] = $TenantId }

    # THE CLOUD HAS TO COME FROM THE READ SESSION, because Connect-MgGraph defaults to Global
    # and a sovereign tenant id is not resolvable there. Sent to a China tenant, the Global
    # authority (login.microsoftonline.com) rejects the sign-in before any consent screen, and
    # all the caller sees is "InteractiveBrowserCredential authentication failed:" with nothing
    # after the colon. Same resolver as Connect-MsecGraphSdk, so read and write land together.
    $graphResource = if ($script:MsecSession -and $script:MsecSession.Endpoints -and
                         $script:MsecSession.Endpoints.GraphResource) {
        $script:MsecSession.Endpoints.GraphResource
    }
    $environment = Resolve-MsecGraphEnvironment -GraphResource $graphResource
    if ($environment -ne 'Global') { $connectArgs['Environment'] = $environment }

    # SAID OUT LOUD SO IT CAN BE QUOTED. "Which scopes does it actually ask for?" is the
    # first question an administrator asks when consent is refused, and the answer was
    # previously only discoverable by reading this file.
    # The format string is parenthesised BEFORE -f. Without it, -f binds tighter than + and
    # formats only the last fragment, leaving {0} in the output as literal text.
    Write-Verbose (("Requesting {0} delegated scope(s) on Microsoft Graph Command Line Tools " +
                    "(appId 14d82eec-204b-4c2f-b7e8-296a70dab67e) in tenant {1} ({2} cloud): {3}") -f
                   @($Scope).Count, $(if ($TenantId) { $TenantId } else { '(default)' }),
                   $environment, ($Scope -join ', '))

    Connect-MgGraph @connectArgs

    $context = Get-MgContext
    if (-not $context) { throw 'Connect-MgGraph returned no context. The sign-in did not complete.' }

    # See the help: a declined scope is not an error, it is an absence.
    $granted = @($context.Scopes)

    # THE TOKEN CARRIES MORE THAN WAS ASKED FOR, and reading the difference as "msec requested
    # all this" is the obvious mistake. Entra issues a token holding every scope already
    # consented for this account on this application, so a long list here reflects consent
    # history, not this command. Measured on one tenant: three scopes requested, forty-two
    # returned.
    Write-Verbose (("Token carries {0} scope(s) - everything previously consented for {1} on this " +
                    "application, not only the {2} requested above: {3}") -f
                   $granted.Count, $context.Account, @($Scope).Count, ($granted -join ', '))
    $missing = @($Scope | Where-Object { $_ -notin $granted })
    if ($missing.Count) {
        throw ("Signed in as $($context.Account), but the tenant did not grant: $($missing -join ', '). " +
               "Connect-MgGraph does not fail on a declined scope - it returns a context without it, and the " +
               "first write would 403 naming nothing. An administrator must consent these for the Microsoft " +
               "Graph PowerShell application. Granted: $($granted -join ', ')")
    }

    # Reading one tenant and writing to another is silently wrong rather than loudly broken.
    if ($script:MsecSession -and $script:MsecSession.TenantId -and
        $context.TenantId -and $context.TenantId -ne $script:MsecSession.TenantId) {
        # REFUSED WITHOUT PURGING THE SHARED SIGN-IN. See the note on the account check below.
        $script:MsecAdminSession = $null
        throw ("Connect-Msec is reading tenant $($script:MsecSession.TenantId) but this sign-in landed on " +
               "$($context.TenantId). Refusing rather than writing to a different tenant than you are reading. " +
               'No write session was established. Pass -TenantId explicitly if that is genuinely what you intend.')
    }

    # THE ACCOUNT MATTERS AS MUCH AS THE TENANT, and only this check can tell them apart.
    # Connect-MgGraph has no -Account parameter, so the browser decides which identity is
    # used and it prefers whichever one it remembers. With two tenants and two identities
    # that silently produces the wrong one - and the failure arrives as AADSTS500213, "the
    # resource tenant's cross-tenant access policy does not allow this user", which reads as
    # a tenant policy problem and sends you to the wrong team. Warned about by name here.
    $profile = Get-MsecTenantProfile -TenantId ([string] $context.TenantId)

    # An EXPECTED account is a refusal, not a warning. Being told afterwards that the write
    # session belongs to the wrong identity is no use once a Set-* has run.
    $expected = if ($Account) { $Account } else { $null }
    if ($expected -and $expected -ne [string] $context.Account) {
        # REFUSED WITHOUT Disconnect-MgGraph, AND THAT IS THE POINT. The SDK's own words: "you
        # will remain signed in until you invoke Disconnect-MgGraph... sign-in persists across
        # PowerShell sessions because Microsoft Graph PowerShell securely caches the token."
        # Purging here destroyed exactly that, so with two identities every switch tore down
        # the sign-in it had just made and the next one started from an empty cache - a browser
        # on every single context switch, forever. Leaving the cache intact lets both accounts
        # accumulate, which is what "sign in once per account" needs.
        #
        # SAFE BECAUSE msec's OWN GATE IS SEPARATE: Assert-MsecAdminSession requires
        # $script:MsecAdminSession, which is cleared here and never set on this path, so no
        # Set-Msec* command can run against the wrong identity.
        $script:MsecAdminSession = $null
        throw ("Asked to sign in as $expected but the sign-in landed on $($context.Account). " +
               'Connect-MgGraph cannot choose the account - the browser reuses whichever it ' +
               'remembers - so no write session was established. Sign in again and pick ' +
               '"Use another account"; run Disconnect-MgGraph first only if the browser will ' +
               'not offer the chooser, since that also clears the cached sign-in.')
    }

    # No expectation passed: fall back to warning against what this tenant used last time.
    if (-not $expected -and $profile -and $profile.AdminAccount -and
        $profile.AdminAccount -ne [string] $context.Account) {
        Write-Warning ("Signed in as $($context.Account), but the last admin session for tenant " +
            "$($context.TenantId) was $($profile.AdminAccount). If that is not deliberate, sign in " +
            'again choosing the other account - the browser reuses whichever it remembers, and a ' +
            'wrong one here fails later as a cross-tenant policy error.')
    }

    # Remembered so the next sign-in into this tenant can make the comparison above. A UPN,
    # saved beside the app profile - no token and no credential is stored.
    if ($profile) {
        Save-MsecTenantProfile -TenantId ([string] $context.TenantId) `
            -KeyVaultName $profile.KeyVaultName -ClientId $profile.ClientId `
            -CertificateName $profile.CertificateName `
            -AdminAccount ([string] $context.Account)
    }

    $script:MsecAdminSession = [PSCustomObject]@{
        PSTypeName   = 'MsecAdminSession'
        Account      = [string] $context.Account
        TenantId     = [string] $context.TenantId
        GrantedScope = $granted
        ConnectedUtc = [datetime]::UtcNow
    }

    Write-Verbose "Write session established as $($context.Account) in tenant $($context.TenantId)."

    $script:MsecAdminSession
    if ($PassThru) { $context }
}
