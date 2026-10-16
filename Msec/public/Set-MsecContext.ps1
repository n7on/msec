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

        IT DISCONNECTS WHAT IT CANNOT REALIGN. Exchange, Teams, SharePoint and Purview sessions
        live inside other modules and cannot be re-pointed at a new tenant - only torn down and
        built again. Left alone they KEEP WORKING against the tenant you just left, returning
        correct-looking data from the wrong place, which is worse than being disconnected. Any
        that are connected are dropped, and you reconnect the ones you need. Use -KeepWorkload
        to leave them, which is only sensible when the new context is the same tenant.

        IT WILL NOT START A WRITE SESSION YOU DID NOT HAVE, unless -Admin is passed. Signing in
        is interactive, and an interactive prompt in the middle of a context switch is a
        surprise. An EXISTING write session is always moved, because leaving it behind is the
        dangerous case.

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

        [switch] $KeepWorkload
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
    try {
        $null = Set-AzContext -Subscription $c.SubscriptionId -Tenant $c.TenantId -ErrorAction Stop
    }
    catch {
        throw ("Could not switch the Azure context to subscription $($c.Subscription) ($($c.SubscriptionId)) " +
               "in tenant $($c.TenantId): $($_.Exception.Message) Nothing else was changed.")
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
    # Moved when one already exists; started only on request. See the help.
    $wantAdmin = $Admin -or [bool] $script:MsecAdminSession
    if ($wantAdmin -and -not $c.AdminAccount) {
        Write-Warning ("Context '$Name' has no admin account recorded, so the write session was not established. " +
                       'Connect-MsecAdmin once and re-run Save-MsecContext to record it.')
    }
    elseif ($wantAdmin) {
        try {
            Connect-MsecAdmin -TenantId $c.TenantId -Account $c.AdminAccount | Out-Null
        }
        catch {
            Write-Warning ("Switched to '$Name', but the write session did not establish as $($c.AdminAccount): " +
                           "$($_.Exception.Message) Set-Msec* commands will not work until Connect-MsecAdmin succeeds.")
        }
    }

    Get-MsecContext
}
