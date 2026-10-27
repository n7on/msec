function Set-MsecContext {
    <#
    .SYNOPSIS
        Switches the Azure context, the msec app session and - when the context has one - the
        write session, together, by name.

    .DESCRIPTION
        THE THREE SESSIONS MOVING SEPARATELY IS THE PROBLEM THIS SOLVES. The Az context, the
        app session and the delegated write session each have their own command and their own
        idea of which tenant they are on. Moving one and forgetting another leaves commands
        reading one tenant and writing to a different one, which fails silently rather than
        loudly.

        THE SWITCH IS SHELL-LOCAL, UNLIKE Set-AzContext's OWN DEFAULT. Az's context autosave
        writes the active context to ~/.Azure/AzureRmContext.json, so switching here would
        otherwise become the default for every shell opened afterwards - discovered later, in a
        different window, aimed at a tenant nobody remembers choosing. The app session and the
        write session already die with the shell; the Az context was the one that did not.
        -Scope CurrentUser asks for the old behaviour.

        IT DISCONNECTS WHAT IT CANNOT REALIGN. Exchange, Teams, SharePoint and Purview sessions
        live inside other modules and cannot be re-pointed at a new tenant - only torn down and
        built again. Left alone they KEEP WORKING against the tenant you just left, returning
        correct-looking data from the wrong place, which is worse than being disconnected. Any
        that are connected are dropped, and you reconnect the ones you need. Use -KeepWorkload
        to leave them, which is only sensible when the new context is the same tenant.

        IT WILL NOT START A WRITE SESSION YOU DID NOT HAVE, unless -Admin is passed. Signing in
        is interactive, and an interactive prompt in the middle of a context switch is a
        surprise.

        A WRITE SESSION FOR ANOTHER TENANT IS DISCONNECTED, NOT CARRIED OVER. Leaving it is
        the dangerous case - it would go on accepting writes aimed at the tenant you just left.
        Re-establishing it is not possible without a browser, so it is dropped and -Admin signs
        back in when you actually intend to write. A session already on the right tenant and
        account is left alone entirely.

        THE REASON IT CANNOT BE CARRIED OVER IS THE GRAPH SDK, not caching. Az keeps a context
        per account and Set-AzContext selects one, so the Azure half of a switch is free. The
        Graph SDK has no context store at all - no Set-MgContext, no list of cached logins, and
        no -Account or -LoginHint on Connect-MgGraph (checked on SDK 2.37.0) - so any change of
        identity must go through an interactive sign-in. Contexts that share one account are
        the exception: there the session stays valid and nothing is dropped.

        THE ADMIN ACCOUNT IS ASSERTED, NOT CHOSEN. Connect-MgGraph has no way to pick an
        identity - the browser reuses whichever it remembers - so the saved account is passed
        to Connect-MsecAdmin, which REFUSES a sign-in that lands on anyone else. That turns a
        wrong-tenant write into an error at the moment it can still be fixed.

        A FAILED RECONNECT DOES NOT UNDO THE SWITCH. The context change is what was asked for
        and it stands; losing a session is reported, loudly, and Get-MsecContext will show it.

    .PARAMETER Name
        The saved context to switch to. Tab-completes.

    .PARAMETER Admin
        Also establish the write session, signing in if there is not one already. Without it,
        an existing write session is moved but a missing one is left missing.

    .PARAMETER Scope
        Where the switch applies. 'Process' (default) changes this shell only. 'CurrentUser'
        writes it to the shared Az profile, making it the default for every new shell.

        The default is deliberately NOT Az's. Context autosave is on for the user, so a switch
        would otherwise follow you into every terminal you open afterwards.

        IT APPLIES TO THE AZURE CONTEXT ONLY. 'CurrentUser' does NOT persist a write session
        started by -Admin - that one keeps its own Process default, because caching a delegated
        write token on disk is a separate decision from choosing a default subscription. Pass
        Connect-MsecAdmin -ContextScope CurrentUser yourself if you want that too.

    .PARAMETER KeepWorkload
        Leave Exchange, Teams, SharePoint and Purview sessions alone. Only sensible when the
        new context is the same tenant - otherwise they go on answering for the old one.

    .EXAMPLE
        Set-MsecContext prod

    .EXAMPLE
        Set-MsecContext prod -Admin
        Get-MsecContext

        Switch everything including the write session, then confirm all surfaces agree.

    .OUTPUTS
        The context rows after the switch, same shape as Get-MsecContext.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $word = ([string]$wordToComplete).Trim("'`"")
                try { $all = (& (Get-Module Msec) { Read-MsecContextStore }) } catch { return }
                $all.Keys | Where-Object { $_ -like "$word*" } | ForEach-Object {
                    $c = $all[$_]
                    $t = if ($_ -match '[\s'']') { "'" + ($_ -replace "'", "''") + "'" } else { $_ }
                    [System.Management.Automation.CompletionResult]::new(
                        $t, $_, 'ParameterValue', "$($c.Subscription) / $($c.KeyVaultName)")
                }
            })]
        [string] $Name,

        [switch] $Admin,

        [switch] $KeepWorkload,

        # SHELL-LOCAL BY DEFAULT, matching Connect-MsecAzure and Connect-MsecAdmin. Az's
        # context autosave writes the active context to ~/.Azure/AzureRmContext.json, so
        # switching here would otherwise re-point every shell opened afterwards - found later,
        # in another window, aimed at a tenant nobody remembers choosing. The app session and
        # the write session already die with the shell; this is the third of the three that
        # did not.
        [ValidateSet('Process', 'CurrentUser')]
        [string] $Scope = 'Process'
    )

    $store = Read-MsecContextStore
    if (-not $store.Contains($Name)) {
        throw "No saved context named '$Name'. Get-MsecContext -List shows what there is; Save-MsecContext creates one."
    }
    $c = $store[$Name]

    if (-not $PSCmdlet.ShouldProcess($Name, 'Switch msec context')) { return }

    # ---- 1. workloads first, while the OLD tenant is still the current one --------------
    # Dropped before anything moves, so a half-switched state never has a live session
    # answering for a tenant that is no longer current.
    if (-not $KeepWorkload) {
        foreach ($w in @(
            @{ Module = 'ExchangeOnlineManagement'; Command = 'Disconnect-ExchangeOnline'; Label = 'Exchange/Purview' }
            @{ Module = 'MicrosoftTeams';           Command = 'Disconnect-MicrosoftTeams'; Label = 'Teams' }
            @{ Module = 'PnP.PowerShell';           Command = 'Disconnect-PnPOnline';      Label = 'SharePoint' }
        )) {
            if (-not (Get-Module -Name $w.Module)) { continue }
            if (-not (Get-Command $w.Command -ErrorAction SilentlyContinue)) { continue }
            try {
                & $w.Command -ErrorAction Stop -Confirm:$false
                Write-Verbose "Disconnected $($w.Label) before switching."
            }
            catch {
                # Usually "not connected", which is fine and not worth a warning.
                Write-Verbose "$($w.Label): nothing to disconnect ($($_.Exception.Message))"
            }
        }
    }

    # ---- 2. Azure context ---------------------------------------------------------------
    # PREFER A CONTEXT Az HAS ALREADY CACHED, because -Subscription/-Tenant resolves the
    # subscription INSIDE THE CURRENT ACCOUNT. Signed in to one cloud, switching to a context
    # in another fails with "Please provide a valid tenant or a valid subscription" even though
    # the target context is sitting in the cache, fully usable - Az just never looked at it.
    # A cached context carries its own account and environment, so selecting it crosses clouds.
    $cached = @(Get-AzContext -ListAvailable -ErrorAction SilentlyContinue |
                    Where-Object { $_.Subscription -and $_.Subscription.Id -eq $c.SubscriptionId -and
                                   $_.Tenant -and $_.Tenant.Id -eq $c.TenantId })

    try {
        if ($cached.Count -ge 1) {
            if ($cached.Count -gt 1) {
                Write-Verbose ("{0} cached Azure contexts match this subscription and tenant; using the one for account {1}." -f
                               $cached.Count, $cached[0].Account.Id)
            }
            $null = Set-AzContext -Context $cached[0] -Scope $Scope -ErrorAction Stop
        }
        else {
            $null = Set-AzContext -Subscription $c.SubscriptionId -Tenant $c.TenantId -Scope $Scope -ErrorAction Stop
        }
    }
    catch {
        # NAME THE CLOUD WHEN IT CHANGED, since that is the whole explanation and the Az error
        # does not mention it. Contexts saved before Environment was recorded have none, and
        # guessing one would be worse than saying nothing.
        $hint = ''
        $now  = (Get-AzContext -ErrorAction SilentlyContinue)
        if ($c.Environment -and $now -and $now.Environment -and $now.Environment.Name -ne $c.Environment) {
            $hint = (" This context is in the {0} cloud and you are signed in to {1}; Azure needs a separate " +
                     "sign-in per cloud. Run: Connect-AzAccount -Environment {0}") -f $c.Environment, $now.Environment.Name
        }
        throw ("Could not switch the Azure context to subscription $($c.Subscription) ($($c.SubscriptionId)) " +
               "in tenant $($c.TenantId): $($_.Exception.Message)$hint Nothing else was changed.")
    }

    # ---- 3. app session ------------------------------------------------------------------
    try {
        # -CertificateName only when the context actually has one. Passing an empty string
        # fails parameter binding, where omitting it lets Connect-Msec apply its own default.
        $connect = @{ KeyVaultName = $c.KeyVaultName; ClientId = $c.ClientId
                      TenantId = $c.TenantId; NoSave = $true }
        if ($c.CertificateName) { $connect['CertificateName'] = $c.CertificateName }
        Connect-Msec @connect | Out-Null
    }
    catch {
        Write-Warning ("Azure context switched to '$Name', but the msec app session did not reconnect " +
                       "(vault $($c.KeyVaultName)): $($_.Exception.Message) Get-Msec* commands will fail until " +
                       'Connect-Msec succeeds.')
    }

    # ---- 4. write session ----------------------------------------------------------------
    # STARTED ONLY ON REQUEST, AND OTHERWISE DISCONNECTED. Re-establishing it on every switch
    # is not possible without a browser: the Graph SDK has no context store and no way to name
    # a cached identity - no Set-MgContext, no -Account, no -LoginHint (SDK 2.37.0) - so a
    # change of identity always goes through an interactive Connect-MgGraph. Az has
    # Get-AzContext -ListAvailable and Set-AzContext and therefore switches for free; Graph has
    # neither. So switching is kept silent and the write session is dropped, exactly as the
    # Exchange, Teams, SharePoint and Purview sessions are. Pass -Admin on the switch where you
    # actually intend to write.
    $adminSession = $script:MsecAdminSession
    $stillValid = $adminSession -and $adminSession.TenantId -eq $c.TenantId -and
                  ((-not $c.AdminAccount) -or $adminSession.Account -eq $c.AdminAccount)

    if ($stillValid) {
        # Same tenant and same account: as good after the switch as before it, so nothing to do.
        Write-Verbose "Write session is already $($adminSession.Account) in this tenant; left alone."
    }
    elseif ($Admin -and -not $c.AdminAccount) {
        Write-Warning ("Context '$Name' has no admin account recorded, so no write session was established. " +
                       'Connect-MsecAdmin once and re-run Save-MsecContext to record it.')
    }
    elseif ($Admin) {
        # A BROWSER IS EXPECTED HERE when the identity changes, and -Admin is the request for
        # it. The account is passed so a sign-in landing on the identity the browser happens to
        # remember is REFUSED rather than silently writing as the wrong person.
        if ($adminSession -and $adminSession.Account -and $adminSession.Account -ne $c.AdminAccount) {
            Write-Verbose ("Signing in as $($c.AdminAccount); the previous session was " +
                           "$($adminSession.Account), and a different identity cannot reuse a cached token.")
        }
        try {
            Connect-MsecAdmin -TenantId $c.TenantId -Account $c.AdminAccount | Out-Null
        }
        catch {
            Write-Warning ("Switched to '$Name', but the write session did not establish as $($c.AdminAccount): " +
                           "$($_.Exception.Message) Set-Msec* commands will not work until Connect-MsecAdmin succeeds.")
        }
    }
    elseif ($adminSession) {
        # DROPPED, because it now belongs to the tenant you just left and would go on accepting
        # writes aimed at it. Disconnect-MgGraph rather than just clearing msec's own variable,
        # so "no write session" means it everywhere and not only to this module.
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {
            try { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
            catch { Write-Verbose "Nothing to disconnect: $($_.Exception.Message)" }
        }
        $script:MsecAdminSession = $null
        Write-Warning ("The write session as $($adminSession.Account) belonged to the tenant you just left and " +
                       "has been disconnected. Run Set-MsecContext '$Name' -Admin when you need to write here.")
    }

    Get-MsecContext
}
