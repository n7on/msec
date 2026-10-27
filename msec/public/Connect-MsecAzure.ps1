function Connect-MsecAzure {
    <#
    .SYNOPSIS
        Signs in to the Azure plane as YOU, for the commands that read ARM rather than Graph.

    .DESCRIPTION
        The module has three ways in and this is the third. Connect-Msec reads as the
        application, Connect-MsecAdmin writes as you through Graph, and the Azure-plane
        commands - Search-MsecLogAnalytics, Get-MsecAzureSecureScore, Get-MsecKeyVaultCertificate
        and the rest - run on the Az context, which is neither. Until now they told you to go
        and run Connect-AzAccount, a cmdlet whose defaults disagree with this module's.

        IT DEFAULTS TO -Scope Process, WHERE Connect-AzAccount DEFAULTS TO CurrentUser. That is
        the whole reason this exists. Az's context autosave writes the active context to
        ~/.Azure/AzureRmContext.json, so a sign-in in one shell silently becomes the default
        for every shell you open afterwards - you discover it later, in a different window,
        pointed at a tenant you do not remember choosing. Here the sign-in belongs to the shell
        that did it, and -Scope CurrentUser is how you ask for the old behaviour.

        THE CREDENTIAL IS SHARED WHATEVER THE SCOPE, and -Scope does not change that. The token
        goes into the OS credential store - on macOS the keychain, under the service name
        Microsoft.Developer.IdentityService - which is per user, not per process. What -Scope
        controls is the POINTER: which tenant and subscription a shell is aimed at. That is the
        part that decides where a command lands, and the part worth keeping local.

        ON macOS THE BROKER BREAKS INTERACTIVE SIGN-IN, and the error does not say so. Az 5.x
        enables the WAM broker by default (EnableLoginByWam), and it must run on the main
        thread, which the PowerShell host does not give it. The failure reads
        "InteractiveBrowserCredential authentication failed: Interactive requests with mac
        broker enabled must be executed on the main thread on macOS" and nothing about it
        suggests a configuration setting is at fault. A sign-in that fails this way is caught
        here and re-thrown naming the fix, and -UseDeviceCode gets you in meanwhile.

        A SOVEREIGN CLOUD IS SLOW, AND THE SLOW PART IS AFTER THE BROWSER. Measured on one
        machine: ~0.08 s per ARM round trip on AzureCloud against ~2.3 s on AzureChinaCloud.
        The sign-in itself is quick; what follows is Az building a context per subscription it
        can see, 25 of them by default, each a round trip. Use -MaxContextPopulation to cut it,
        and -Verbose to see where the time actually went.

        A SOVEREIGN CLOUD NEEDS -Environment AND FAILS OPAQUELY WITHOUT IT. Azure requires a
        separate sign-in per cloud; an account in one cannot see a tenant in another. Sent to
        the wrong authority the sign-in is refused before any prompt, with no mention of the
        cloud.

    .PARAMETER Subscription
        Subscription to select once signed in, by name or id. Without it you get whatever Azure
        considers your default, which on an account with many subscriptions is rarely the one
        you meant.

    .PARAMETER TenantId
        Tenant to sign in to. Needed when your account exists in more than one.

    .PARAMETER Environment
        The Azure cloud: AzureCloud (default), AzureChinaCloud, AzureUSGovernment. Required for
        a sovereign tenant - see the description.

        Tab-completes from Get-AzEnvironment, so a cloud registered locally with
        Add-AzEnvironment shows up too. Deliberately NOT a ValidateSet, which would refuse an
        air-gapped or national cloud that genuinely exists.

    .PARAMETER Scope
        Where the sign-in lives. 'Process' (default) keeps it in this shell. 'CurrentUser'
        writes it to the shared Az profile, making it the default for every new shell, which is
        Connect-AzAccount's own default.

    .PARAMETER MaxContextPopulation
        How many subscriptions Az builds a context for after sign-in. Az's own default is 25,
        and each one costs a round trip - which is why a sovereign sign-in can sit for a long
        time after you have already picked the account in the browser. Measured: ~0.08 s per
        ARM round trip on AzureCloud against ~2.3 s on AzureChinaCloud.

        Lower it when you only want one subscription; -1 populates all. It is NOT lowered by
        default, because those populated contexts are what lets Set-MsecContext move between
        clouds without a fresh sign-in.

    .PARAMETER UseDeviceCode
        Sign in with a device code instead of a browser. The way past the macOS broker failure,
        and the way in from a session with no browser at all.

    .PARAMETER PassThru
        Emit the full Az context as well as the summary.

    .EXAMPLE
        Connect-MsecAzure -Subscription 'PROD'

        Signs in for this shell only. Open another terminal and it is still pointed wherever it
        was - which is the point.

    .EXAMPLE
        Connect-MsecAzure -Environment AzureChinaCloud -UseDeviceCode

        A sovereign tenant from a Mac, avoiding both traps at once.

    .OUTPUTS
        One PSCustomObject describing the session, PSTypeName 'MsecAzureConnection'.

    .NOTES
        Signs in as YOU, not as the msec application - this is ARM, and the app holds Graph
        permissions, not Azure RBAC. What you can read is what your own role assignments allow.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Subscription,

        [string] $TenantId,

        # COMPLETED, NOT VALIDATED. Get-AzEnvironment lists the clouds Az knows, which is three
        # out of the box - but Add-AzEnvironment registers more, and air-gapped and national
        # clouds are exactly the case where somebody needs this command most. A ValidateSet
        # would complete nicely and then refuse a cloud that genuinely exists.
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $word = ([string]$wordToComplete).Trim("'`"")
                try { $envs = @(Get-AzEnvironment -ErrorAction Stop) } catch { return }
                $envs | Where-Object { $_.Name -like "$word*" } | ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new(
                        $_.Name, $_.Name, 'ParameterValue', [string] $_.ResourceManagerUrl)
                }
            })]
        [string] $Environment,

        # SHELL-LOCAL BY DEFAULT, deliberately unlike Connect-AzAccount. See the help: the
        # credential is shared through the OS credential store whatever this says, so the only
        # thing being scoped is which tenant and subscription this shell points at.
        [ValidateSet('Process', 'CurrentUser')]
        [string] $Scope = 'Process',

        # THE LEVER FOR A SLOW CLOUD. After the browser step Az builds a context per
        # subscription it can see, capped at 25 by default, and each one is a round trip.
        # Measured: ~0.08 s per ARM round trip on AzureCloud against ~2.3 s on
        # AzureChinaCloud - 28x - so the populate phase that is invisible on the commercial
        # cloud is where a sovereign sign-in appears to hang after you have already picked
        # the account. Lower it when you only care about one subscription; -1 means all.
        #
        # NOT LOWERED BY DEFAULT, because those populated contexts are what lets
        # Set-MsecContext switch between clouds without signing in again.
        [int] $MaxContextPopulation,

        [switch] $UseDeviceCode,

        [switch] $PassThru
    )

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        throw 'Az.Accounts is required for Connect-MsecAzure. Install with: Install-Module Az.Accounts -Scope CurrentUser'
    }
    Import-Module Az.Accounts -ErrorAction Stop

    $connectArgs = @{ Scope = $Scope; ErrorAction = 'Stop' }
    if ($Subscription)  { $connectArgs['Subscription'] = $Subscription }
    if ($TenantId)      { $connectArgs['Tenant']       = $TenantId }
    if ($Environment)   { $connectArgs['Environment']  = $Environment }
    if ($UseDeviceCode) { $connectArgs['UseDeviceAuthentication'] = $true }
    if ($PSBoundParameters.ContainsKey('MaxContextPopulation')) {
        $connectArgs['MaxContextPopulation'] = $MaxContextPopulation
    }

    Write-Verbose ("Connecting to {0} (scope {1}){2}" -f
                   $(if ($Environment) { $Environment } else { 'AzureCloud' }),
                   $Scope,
                   $(if ($TenantId) { " in tenant $TenantId" } else { '' }))

    # TIMED, so "it hung" can be told from "the browser took a while". The sign-in itself is
    # quick; what follows it is not, on a cloud where every round trip costs seconds.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Connect-AzAccount @connectArgs
        $sw.Stop()
        Write-Verbose ("Connect-AzAccount returned in {0:N1} s." -f $sw.Elapsed.TotalSeconds)
    }
    catch {
        $sw.Stop()
        # THE macOS BROKER FAILURE NAMED, because its own message does not name the cause and
        # the setting behind it is not something anyone would think to look for.
        $m = [string] $_.Exception.Message
        if ($m -match 'main thread' -or $m -match 'broker') {
            throw ("Azure sign-in failed because the macOS broker (WAM) cannot run on this thread. " +
                   "Turn it off once with: Update-AzConfig -EnableLoginByWam `$false  - or sign in " +
                   "now with: Connect-MsecAzure -UseDeviceCode. Original error: $m")
        }
        throw "Azure sign-in failed: $m"
    }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) { throw 'Connect-AzAccount returned no context. The sign-in did not complete.' }

    # SAID OUT LOUD, because "which subscription am I actually on" is the question every one of
    # these commands depends on and the sign-in itself does not answer clearly.
    $out = [PSCustomObject]@{
        PSTypeName     = 'MsecAzureConnection'
        Account        = [string] $ctx.Account.Id
        Subscription   = [string] $ctx.Subscription.Name
        SubscriptionId = [string] $ctx.Subscription.Id
        TenantId       = [string] $ctx.Tenant.Id
        Environment    = [string] $ctx.Environment.Name
        Scope          = $Scope
    }

    if ($Scope -eq 'CurrentUser') {
        Write-Verbose 'Scope CurrentUser: this is now the default context for every new shell.'
    }

    if ($PassThru) { $ctx } else { $out }
}
