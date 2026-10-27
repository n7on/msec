function Get-MsecEntraGuest {
    <#
    .SYNOPSIS
        Guest accounts, whether each one was ever redeemed, and when it was last actually
        used - the identities in the directory that belong to someone outside the tenant.

    .DESCRIPTION
        A guest is a real account in the directory. It can be added to groups, granted access
        to sites and teams, and consented to apps, and it is governed by whatever Conditional
        Access covers guests - which in many tenants is less than covers members. The two
        questions worth asking are whether anyone is behind it and whether anyone still uses
        it, and neither is on the user object in a form you can read directly.

        AN INVITATION IS NOT AN ACCOUNT SOMEONE USES. InvitationState 'PendingAcceptance'
        means the account exists and the invitation was never redeemed - nobody has ever
        signed in as it, yet it can already hold group membership and permissions granted in
        anticipation. Measured on one tenant: 107 of 222 guests, 48%, had never redeemed.
        Those are not users; they are access waiting for someone who never arrived.

        'NEVER SIGNED IN' MUST NOT BE READ OFF lastSignInDateTime, WHICH IS INTERACTIVE ONLY.
        An account signing in daily through refresh tokens or a service integration leaves
        that field EMPTY while lastNonInteractiveSignInDateTime moves every day. Taking the
        interactive field alone reports an account in active use as dormant - measured on the
        same tenant, 111 guests looked dormant that way and 109 genuinely were, so two
        actively-signing-in accounts would have been proposed for deletion. LastSignInUtc here
        is the LATEST of the interactive, non-interactive and last-successful timestamps, and
        LastSignInKind says which one it came from.

        A TENANT WHERE NO GUEST HAS SIGN-IN DATA IS A PERMISSION PROBLEM, NOT AN IDLE TENANT.
        Graph omits signInActivity entirely - silently, with no error and no property - when
        the caller lacks 'AuditLog.Read.All'. Every guest then looks like it has never signed
        in, which is the single most dangerous way this command could be wrong: it reads as a
        list of accounts safe to delete. So when not one guest carries sign-in data the
        command WARNS, and SignInDataAvailable is false on every row.

        Runs as the msec app. Needs 'User.Read.All' for the accounts and 'AuditLog.Read.All'
        for the sign-in half; without the latter the account half still works.

    .PARAMETER PendingOnly
        Only guests whose invitation was never redeemed.

    .PARAMETER NeverSignedIn
        Only guests with no sign-in of any kind. Counts non-interactive activity, so an
        account used by an integration is not included.

    .PARAMETER InactiveDays
        Only guests whose last sign-in is older than this many days. Guests that have never
        signed in at all are NOT returned - that is -NeverSignedIn, and conflating the two
        hides which of the pair you are looking at.

    .PARAMETER Domain
        Only guests whose mail address is in this domain, e.g. 'contoso.com'.

    .EXAMPLE
        Get-MsecEntraGuest | Format-Table DisplayName, InvitationState, LastSignInUtc, Domain

    .EXAMPLE
        # Invitations nobody ever redeemed - access granted to an absent person.
        Get-MsecEntraGuest -PendingOnly

    .EXAMPLE
        # Redeemed once, then abandoned. The deletion candidates that are NOT merely pending.
        Get-MsecEntraGuest -InactiveDays 180

    .EXAMPLE
        # Which organisations hold accounts here, largest first.
        Get-MsecEntraGuest | Group-Object Domain | Sort-Object Count -Descending

    .OUTPUTS
        PSCustomObject per guest, PSTypeName 'MsecEntraGuest'.

    .NOTES
        Read-only. Deleting a guest removes its access everywhere at once, which is the point
        and also the risk: check group membership with Get-MsecEntraGroupMember first, since a
        guest can be the only external member of something that matters.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $PendingOnly,
        [switch] $NeverSignedIn,
        [ValidateRange(1, 3650)]
        [int] $InactiveDays,
        [string] $Domain
    )

    Assert-MsecSession

    $select = @(
        'id', 'displayName', 'userPrincipalName', 'mail', 'accountEnabled', 'createdDateTime',
        'externalUserState', 'externalUserStateChangeDateTime', 'creationType', 'companyName',
        'signInActivity'
    ) -join ','

    try {
        $guests = @(Invoke-MsecGraphRequest -All `
            -Path "/v1.0/users?`$filter=userType eq 'Guest'&`$select=$select&`$top=999")
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw ("Forbidden listing guests. The msec app needs 'User.Read.All', and " +
                   "'AuditLog.Read.All' for the sign-in columns. Original error: $($_.Exception.Message)")
        }
        throw
    }

    # Graph drops signInActivity silently when AuditLog.Read.All is missing - no error, no
    # property. If NOT ONE guest has it, that is the permission, not an idle tenant, and the
    # difference decides whether this output is a deletion list or a false one.
    $withSignIn = @($guests | Where-Object { $_.signInActivity }).Count
    $signInAvailable = $withSignIn -gt 0
    if ($guests.Count -gt 0 -and -not $signInAvailable) {
        Write-Warning ("No guest carries sign-in data, so every row below reports LastSignInUtc " +
            "as null. This is NOT evidence that no guest has signed in: Graph omits " +
            "signInActivity entirely, without error, when the caller lacks 'AuditLog.Read.All'. " +
            'Grant that permission before treating any of these as unused.')
    }

    $now = [datetime]::UtcNow

    foreach ($g in $guests) {
        $mail   = [string]$g.mail
        if (-not $mail) { $mail = [string]$g.userPrincipalName }
        # A guest UPN is mangled - alex_contoso.com#EXT#@tenant.onmicrosoft.com - so the home
        # domain comes from mail, falling back to unpicking the UPN.
        #
        # NOT $domain: PowerShell variable names are case-insensitive, so a local $domain IS
        # the -Domain parameter, and the first row would overwrite the filter with its own
        # value - after which -Domain matches only guests from the first guest's domain.
        $guestDomain = if ($mail -match '@') { ($mail -split '@')[-1] }
                      elseif ($mail -match '_') { ($mail -split '#EXT#')[0] -replace '.*_', '' }
                      else { '' }

        if ($Domain -and $guestDomain -ne $Domain) { continue }

        $state = [string]$g.externalUserState
        if ($PendingOnly -and $state -ne 'PendingAcceptance') { continue }

        # The LATEST of the three, not the interactive one - see the description.
        $stamps = @(
            $g.signInActivity.lastSignInDateTime
            $g.signInActivity.lastNonInteractiveSignInDateTime
            $g.signInActivity.lastSuccessfulSignInDateTime
        ) | Where-Object { $_ }

        $lastSignIn = $null
        if ($stamps) { $lastSignIn = ($stamps | ForEach-Object { [datetime]$_ } | Sort-Object -Descending)[0] }

        # Which signal it came from, so an account that is only ever non-interactive is
        # visible as that rather than silently counted as a normal sign-in.
        $kind = if (-not $lastSignIn) { 'None' }
                elseif ($g.signInActivity.lastSignInDateTime -and
                        [datetime]$g.signInActivity.lastSignInDateTime -eq $lastSignIn) { 'Interactive' }
                else { 'NonInteractive' }

        if ($NeverSignedIn -and $lastSignIn) { continue }

        # Never-signed-in is deliberately NOT inactive-for-N-days: they are different findings
        # and merging them hides which one a row represents.
        if ($InactiveDays) {
            if (-not $lastSignIn) { continue }
            if ($lastSignIn -gt $now.AddDays(-$InactiveDays)) { continue }
        }

        $invited = $null
        if ($g.createdDateTime) { $invited = [datetime]$g.createdDateTime }

        [PSCustomObject]@{
            PSTypeName          = 'MsecEntraGuest'
            DisplayName         = [string]$g.displayName
            Mail                = $mail
            Domain              = $guestDomain
            UserPrincipalName   = [string]$g.userPrincipalName
            # 'PendingAcceptance' means nobody ever redeemed the invitation.
            InvitationState     = $state
            AccountEnabled      = [bool]$g.accountEnabled
            InvitedUtc          = $invited
            DaysSinceInvite     = if ($invited) { [int]($now - $invited).TotalDays } else { $null }
            LastSignInUtc       = $lastSignIn
            LastSignInKind      = $kind
            DaysSinceSignIn     = if ($lastSignIn) { [int]($now - $lastSignIn).TotalDays } else { $null }
            # False means the sign-in columns could not be read at all, NOT that the account
            # has never been used.
            SignInDataAvailable = $signInAvailable
            CompanyName         = [string]$g.companyName
            CreationType        = [string]$g.creationType
            Id                  = [string]$g.id
            Raw                 = $g
        }
    }
}
