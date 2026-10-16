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

        THE SESSION OUTLIVES THE SHELL BY DEFAULT, THE SAME WAY Connect-Msec DOES. Its
        read session persists because a tenant profile lets any later session re-authenticate
        with the Key Vault certificate; this one persists because -ContextScope CurrentUser
        caches a refresh token. Connect-MgGraph's own default is Process scope, which left the
        two commands behaving differently - the read session available everywhere, the write
        session only inside the shell that signed in, with an empty MSAL cache file on disk as
        the only clue.

        THAT PERSISTENCE IS A REAL WIDENING, not a convenience. Until the token expires or you
        run Disconnect-MgGraph, any process running as you can obtain a delegated token
        carrying your write scopes, with no prompt and nobody watching. The module's position
        is still that writes belong to a person - that is why they are delegated rather than
        application permissions, and why every change is attributable to a named account - but
        "a person signed in once on this machine" is a weaker claim than "a person is at the
        keyboard now". Use -ContextScope Process where that distinction matters, and
        Disconnect-MgGraph when you are done.

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
        Where the token lives. 'CurrentUser' (default) caches a refresh token so other
        sessions - and other processes running as you - can write. 'Process' keeps it in this
        shell only, which is Connect-MgGraph's own default.

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

        # WHERE THE TOKEN LIVES, AND IT DEFAULTS TO SURVIVING THIS SHELL - matching
        # Connect-Msec, which saves a tenant profile that any later session replays.
        #
        # Connect-MgGraph's own default is 'Process': the token stays in the memory of the
        # shell that signed in, the MSAL cache file is created and left EMPTY, and every
        # other process sees no session at all. That is a surprising difference between the
        # module's two connect commands - the read session works everywhere, the write
        # session works in exactly one place - and it was reported as the admin session
        # "not being seen".
        #
        # 'CurrentUser' CACHES A REFRESH TOKEN ON DISK, which is a real widening and the
        # reason this is written down rather than silently flipped: until it expires or you
        # Disconnect-MgGraph, ANY process running as you can obtain a delegated token with
        # your write scopes, without a prompt and without you watching. That is a deliberate
        # trade for making the command behave like its sibling. Use -ContextScope Process
        # for a session that dies with the shell.
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

    # SAID OUT LOUD SO IT CAN BE QUOTED. "Which scopes does it actually ask for?" is the
    # first question an administrator asks when consent is refused, and the answer was
    # previously only discoverable by reading this file.
    # The format string is parenthesised BEFORE -f. Without it, -f binds tighter than + and
    # formats only the last fragment, leaving {0} in the output as literal text.
    Write-Verbose (("Requesting {0} delegated scope(s) on Microsoft Graph Command Line Tools " +
                    "(appId 14d82eec-204b-4c2f-b7e8-296a70dab67e) in tenant {1}: {2}") -f
                   @($Scope).Count, $(if ($TenantId) { $TenantId } else { '(default)' }), ($Scope -join ', '))

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
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        throw ("Connect-Msec is reading tenant $($script:MsecSession.TenantId) but this sign-in landed on " +
               "$($context.TenantId). Refusing rather than writing to a different tenant than you are reading. " +
               'Pass -TenantId explicitly if that is genuinely what you intend.')
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
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        throw ("Asked to sign in as $expected but the sign-in landed on $($context.Account). " +
               'Connect-MgGraph cannot choose the account - the browser reuses whichever it ' +
               'remembers - so the session has been closed rather than left on the wrong identity. ' +
               'Run Disconnect-MgGraph, then sign in again and pick "Use another account".')
    }

    # No expectation passed: fall back to warning against what this tenant used last time.
    if (-not $expected -and $profile -and $profile.AdminAccount -and
        $profile.AdminAccount -ne [string] $context.Account) {
        Write-Warning ("Signed in as $($context.Account), but the last admin session for tenant " +
            "$($context.TenantId) was $($profile.AdminAccount). If that is not deliberate, run " +
            'Disconnect-MgGraph and sign in again choosing the other account - the browser reuses ' +
            'whichever it remembers, and a wrong one here fails later as a cross-tenant policy error.')
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
