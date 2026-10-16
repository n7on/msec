function Save-MsecContext {
    <#
    .SYNOPSIS
        Remembers the current sessions under a name, so Set-MsecContext can put them all back
        together later.

    .DESCRIPTION
        SNAPSHOTS WHAT IS CONNECTED RIGHT NOW, which is why it takes almost no parameters.
        Connect everything the way you want it - Azure context, Connect-Msec, and
        Connect-MsecAdmin if you write in this tenant - then name it. Typing the subscription,
        vault and admin account again by hand is how they drift apart.

        THE ADMIN ACCOUNT IS THE POINT, not an extra. Connect-MgGraph cannot choose an
        identity; the browser reuses whichever it remembers. With two tenants and two
        identities the wrong one is picked silently, and surfaces much later as a write into
        the tenant you did not mean, or as AADSTS500213 - a cross-tenant policy error that
        names nothing about accounts. Recording the account here lets Set-MsecContext refuse a
        mismatch instead of discovering it afterwards.

        NO SECRET IS STORED. Subscription, tenant, vault name, client id, certificate name and
        a UPN - the same things you would type on a command line. msec signs with a key that
        never leaves Key Vault, so there is nothing here worth having.

        Saved at the cache ROOT, not under a tenant folder: a named context exists in order to
        pick a tenant, so it cannot be filed under one.

    .PARAMETER Name
        What to call it. Re-saving an existing name overwrites it.

    .PARAMETER AdminAccount
        The account the write session must use in this context. Defaults to whatever
        Connect-MsecAdmin is currently signed in as, or to nothing if there is no write
        session - in which case Set-MsecContext will not try to establish one.

    .PARAMETER Force
        Overwrite an existing context of the same name without asking.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-prod
        Connect-MsecAdmin
        Save-MsecContext -Name prod

        The usual flow: get it right once, then name it.

    .EXAMPLE
        Get-MsecContext -List

        What has been saved.

    .OUTPUTS
        The saved context, PSTypeName 'MsecSavedContext'.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 ._-]*$')]
        [string] $Name,

        [string] $AdminAccount,

        [switch] $Force
    )

    $az = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $az) {
        throw 'No Azure context to save. Run Connect-AzAccount and Set-MsecContext first - a context without a subscription cannot be switched back to.'
    }
    if (-not $script:MsecSession) {
        throw 'No msec app session to save. Run Connect-Msec -KeyVaultName <vault> first, so the saved context knows which vault to reconnect with.'
    }

    $store = Read-MsecContextStore
    if ($store.Contains($Name) -and -not $Force -and
        -not $PSCmdlet.ShouldContinue("A context named '$Name' already exists. Replace it?", 'Save-MsecContext')) {
        return
    }

    # Defaults to the live write session. Absent is meaningful: it means this context does not
    # write, and Set-MsecContext will not start a sign-in for it.
    $admin = if ($PSBoundParameters.ContainsKey('AdminAccount')) { $AdminAccount }
             elseif ($script:MsecAdminSession) { [string] $script:MsecAdminSession.Account }
             else { $null }

    # THE SESSION DOES NOT CARRY THE CERTIFICATE NAME - it holds the Key Vault KEY name
    # resolved from the certificate's metadata, which is a different thing and not what
    # Connect-Msec takes. The tenant profile has it; absent, Connect-Msec's own default
    # applies, so an empty value here is recorded as empty rather than guessed at.
    $tp = Get-MsecTenantProfile -TenantId ([string] $script:MsecSession.TenantId)
    $certName = if ($tp -and $tp.CertificateName) { [string] $tp.CertificateName } else { $null }

    $ctx = [PSCustomObject]@{
        PSTypeName      = 'MsecSavedContext'
        Name            = $Name
        SubscriptionId  = [string] $az.Subscription.Id
        Subscription    = [string] $az.Subscription.Name
        AzAccount       = [string] $az.Account.Id
        TenantId        = [string] $script:MsecSession.TenantId
        KeyVaultName    = [string] $script:MsecSession.KeyVaultName
        ClientId        = [string] $script:MsecSession.ClientId
        CertificateName = $certName
        AdminAccount    = $admin
        SavedUtc        = [datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Save msec context')) {
        $store[$Name] = $ctx
        $null = Write-MsecContextStore -Contexts $store
    }
    $ctx
}
