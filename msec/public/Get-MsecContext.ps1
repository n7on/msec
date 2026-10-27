function Get-MsecContext {
    <#
    .SYNOPSIS
        One row per session surface - Azure, the msec app, the write session and each
        workload - with the tenant it is bound to and whether that matches the others.

    .DESCRIPTION
        ANSWERS "WHERE AM I?", WHICH NOTHING ELSE DOES. Working with msec means up to seven
        separate sessions: the Az context, the app-only session from Connect-Msec, the
        delegated session from Connect-MsecAdmin, and one each for Exchange, Teams,
        SharePoint and Purview. Each is established by its own command, each remembers its
        own tenant, and nothing has ever shown them together. Finding out which tenant a
        given command was about to use meant running something and inferring it from the
        answer.

        A STALE SESSION IS THE FAILURE THIS EXISTS FOR, NOT A MISSING ONE. An absent session
        fails loudly and immediately - a command says it is not connected. A session left
        behind on the tenant you switched away from SUCCEEDS, and returns correct-looking
        data from the wrong tenant. Get-EXOMailbox against yesterday's Exchange connection
        does not complain. The Aligned column is the whole point of the command.

        NOT CONNECTED AND CANNOT TELL ARE DIFFERENT, AND BOTH ARE REPORTED. A workload whose
        module is not loaded cannot have a session in this runspace, and says 'ModuleNotLoaded'
        rather than pretending to a clean 'NotConnected'. A probe that throws says 'Unknown'.
        Reporting either as "not connected" would turn "I could not look" into "there is
        nothing there", which is the mistake that makes a stale session invisible.

        IT NEVER CONNECTS, IMPORTS OR DISCONNECTS ANYTHING. Probing a workload by importing
        its module would change the thing being measured, and auto-connecting on a read is
        how a 10-second Exchange sign-in ends up inside an unrelated command. Only modules
        already loaded in this session are asked.

        THE GRAPH SDK AND THE WRITE SESSION SHARE Get-MgContext and are told apart by
        AuthType: Connect-MsecGraphSdk signs in app-only, Connect-MsecAdmin delegated. One
        Get-MgContext result therefore belongs to exactly one of those two rows, and reading
        it as both would report a write session that does not exist.

    .PARAMETER List
        Show the SAVED contexts instead of the live sessions - what you can switch to, rather
        than where you are. Mirrors Get-AzContext -ListAvailable.

    .PARAMETER IncludeWorkload
        Also probe Exchange, Teams, SharePoint and Purview. Off by default: those probes call
        into other modules, and a couple of them are slow enough to notice.

    .EXAMPLE
        Get-MsecContext

        The core three - Azure, app session, write session - and whether they agree.

    .EXAMPLE
        Get-MsecContext -IncludeWorkload | Where-Object Aligned -eq 'DIFFERENT'

        Every session pointing somewhere other than the current Azure context. Empty is the
        answer you want before running anything that writes.

    .OUTPUTS
        One PSCustomObject per surface, PSTypeName 'MsecContext'.

    .NOTES
        Read-only, and local: it inspects session state in this process and calls no API.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $IncludeWorkload,

        # The SAVED contexts rather than the live ones - the same split as Get-AzContext and
        # Get-AzContext -ListAvailable. Answers "what can I switch to", where the default
        # answers "where am I".
        [switch] $List
    )

    if ($List) {
        $store = Read-MsecContextStore
        foreach ($n in $store.Keys) {
            $c = $store[$n]
            [PSCustomObject]@{
                PSTypeName   = 'MsecSavedContext'
                Name         = $n
                Subscription = $c.Subscription
                TenantId     = $c.TenantId
                KeyVaultName = $c.KeyVaultName
                AzAccount    = $c.AzAccount
                # Empty means this context does not write, and Set-MsecContext will not try.
                AdminAccount = $c.AdminAccount
                SavedUtc     = $c.SavedUtc
            }
        }
        return
    }

    # The tenant everything else is compared against. The Az context is the one surface that
    # is always meaningful - it is what Set-MsecContext moves and what the Azure-plane
    # commands run on.
    $azTenant = $null
    $rows = [System.Collections.Generic.List[object]]::new()

    $add = {
        param($Surface, $Status, $Account, $Tenant, $Detail)
        $aligned = if (-not $Tenant -or -not $azTenant) { 'n/a' }
                   elseif ($Tenant -eq $azTenant)       { 'Aligned' }
                   else                                 { 'DIFFERENT' }
        $rows.Add([PSCustomObject]@{
            PSTypeName = 'MsecContext'
            Surface    = $Surface
            Status     = $Status
            Account    = $Account
            TenantId   = $Tenant
            # The column the command exists for - see the help.
            Aligned    = $aligned
            Detail     = $Detail
        })
    }

    # ---- Azure -----------------------------------------------------------------------
    try {
        $az = Get-AzContext -ErrorAction Stop
        if ($az) {
            $azTenant = [string] $az.Tenant.Id
            & $add 'Azure' 'Connected' ([string] $az.Account.Id) $azTenant `
                   ("subscription $($az.Subscription.Name)")
        }
        else { & $add 'Azure' 'NotConnected' $null $null 'Connect-AzAccount' }
    }
    catch { & $add 'Azure' 'Unknown' $null $null $_.Exception.Message }

    # ---- msec app session (Connect-Msec) ---------------------------------------------
    if ($script:MsecSession) {
        & $add 'App (Connect-Msec)' 'Connected' ([string] $script:MsecSession.ClientId) `
               ([string] $script:MsecSession.TenantId) `
               ("vault $($script:MsecSession.KeyVaultName)")
    }
    else { & $add 'App (Connect-Msec)' 'NotConnected' $null $null 'Connect-Msec -KeyVaultName <kv>' }

    # ---- write session (Connect-MsecAdmin) -------------------------------------------
    if ($script:MsecAdminSession) {
        $n = @($script:MsecAdminSession.GrantedScope).Count
        & $add 'Write (Connect-MsecAdmin)' 'Connected' ([string] $script:MsecAdminSession.Account) `
               ([string] $script:MsecAdminSession.TenantId) "$n scope(s) on the token"
    }
    else { & $add 'Write (Connect-MsecAdmin)' 'NotConnected' $null $null 'Connect-MsecAdmin' }

    if (-not $IncludeWorkload) { return $rows }

    # ---- workloads -------------------------------------------------------------------
    # Only modules ALREADY loaded are asked. Importing one to probe it would change the
    # state being reported, and is how a read turns into a sign-in.
    $probe = {
        param($Surface, $ModuleName, $Probe)
        if (-not (Get-Module -Name $ModuleName)) {
            & $add $Surface 'ModuleNotLoaded' $null $null "$ModuleName is not loaded in this session"
            return
        }
        try { & $Probe }
        catch { & $add $Surface 'Unknown' $null $null $_.Exception.Message }
    }

    & $probe 'Graph SDK (app-only)' 'Microsoft.Graph.Authentication' {
        $c = Get-MgContext -ErrorAction Stop
        # Shared with the write session; AuthType is what separates them.
        if ($c -and [string]$c.AuthType -eq 'AppOnly') {
            & $add 'Graph SDK (app-only)' 'Connected' ([string]$c.ClientId) ([string]$c.TenantId) 'app-only'
        }
        else { & $add 'Graph SDK (app-only)' 'NotConnected' $null $null 'Connect-MsecGraphSdk' }
    }

    & $probe 'Exchange Online' 'ExchangeOnlineManagement' {
        $ci = @(Get-ConnectionInformation -ErrorAction Stop)
        # Purview (IPPSSession) surfaces here too; told apart by the endpoint it connected to.
        $exo = @($ci | Where-Object { [string]$_.ConnectionUri -notmatch 'compliance|protection\.outlook' })
        if ($exo) {
            & $add 'Exchange Online' 'Connected' ([string]$exo[0].UserPrincipalName) `
                   ([string]$exo[0].TenantId) ([string]$exo[0].ConnectionUri)
        }
        else { & $add 'Exchange Online' 'NotConnected' $null $null 'Connect-MsecExchangeOnline' }

        $ipps = @($ci | Where-Object { [string]$_.ConnectionUri -match 'compliance|protection\.outlook' })
        if ($ipps) {
            & $add 'Purview' 'Connected' ([string]$ipps[0].UserPrincipalName) `
                   ([string]$ipps[0].TenantId) ([string]$ipps[0].ConnectionUri)
        }
        else { & $add 'Purview' 'NotConnected' $null $null 'Connect-MsecPurview' }
    }

    & $probe 'SharePoint (PnP)' 'PnP.PowerShell' {
        # PnP THROWS INSTEAD OF RETURNING NULL when there is no connection, so the generic
        # catch would file a perfectly knowable "not signed in" under Unknown - blurring the
        # one distinction this command exists to keep sharp. Recognised by message and
        # reported as what it is.
        try {
            $c = Get-PnPConnection -ErrorAction Stop
            if ($c) { & $add 'SharePoint (PnP)' 'Connected' ([string]$c.ClientId) ([string]$c.Tenant) ([string]$c.Url) }
            else    { & $add 'SharePoint (PnP)' 'NotConnected' $null $null 'Connect-MsecSharePointOnline' }
        }
        catch {
            if ("$($_.Exception.Message)" -match 'not signed in|No connection|Connect-PnPOnline') {
                & $add 'SharePoint (PnP)' 'NotConnected' $null $null 'Connect-MsecSharePointOnline'
            }
            else { throw }
        }
    }

    # Teams has no cheap "am I connected" call - Get-CsTenant is a round trip - so the module
    # being loaded is reported WITHOUT claiming a session either way. Saying 'NotConnected'
    # here would be a guess, and this command exists to stop guesses about session state.
    if (Get-Module -Name MicrosoftTeams) {
        & $add 'Teams' 'Unknown' $null $null `
               'MicrosoftTeams is loaded; no cheap probe exists (Get-CsTenant is a round trip)'
    }
    else { & $add 'Teams' 'ModuleNotLoaded' $null $null 'MicrosoftTeams is not loaded in this session' }

    $rows
}
