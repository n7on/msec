function Save-MsecTenantProfile {
    <#
    .SYNOPSIS
        Remembers how to connect to a tenant, so switching Azure context can reconnect the
        msec session without being told the vault again.

    .DESCRIPTION
        Writes the CONFIGURATION needed to call Connect-Msec - vault name, client id,
        certificate name - into the tenant's own cache folder, beside the completion caches.

        NO SECRET IS STORED, and none needs to be. msec authenticates with a JWT client
        assertion signed inside Key Vault; the private key never leaves it. What is here is
        the same information you would type on the command line, and it is worth nothing to
        anyone who cannot already reach the vault.

        Best effort by design: a profile that cannot be written costs the convenience of
        auto-reconnect, not the session. Failing Connect-Msec because a cache folder was
        read-only would be the wrong trade.

    .PARAMETER TenantId
        The tenant this profile connects to. Also the folder it is stored under, so two
        tenants can never overwrite each other's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $KeyVaultName,
        [Parameter(Mandatory)] [string] $ClientId,
        [Parameter()] [string] $CertificateName = 'msec-app',

        # THE ACCOUNT Connect-MsecAdmin SIGNED IN AS, remembered per tenant so a later
        # sign-in can tell "you picked the wrong account" from "you have no consent". Two
        # tenants with two identities is where that distinction stops being obvious: a
        # viedoc user reaching a viedochosting resource fails with AADSTS500213, which
        # names a cross-tenant policy and says nothing about the account being wrong.
        #
        # A UPN, not a secret, and not a credential of any kind.
        [Parameter()] [string] $AdminAccount
    )

    try {
        $path = Get-MsecCachePath -Name 'profile' -TenantId $TenantId
        $dir = Split-Path -Path $path -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

        [pscustomobject]@{
            TenantId        = $TenantId
            KeyVaultName    = $KeyVaultName
            ClientId        = $ClientId
            CertificateName = $CertificateName
            # Preserved when this save is only about the app session, so recording a
            # connection does not forget which admin account belongs to this tenant.
            AdminAccount    = if ($PSBoundParameters.ContainsKey('AdminAccount')) { $AdminAccount }
                              else { (Get-MsecTenantProfile -TenantId $TenantId).AdminAccount }
            SavedUtc        = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop

        Write-Verbose "Saved the connection profile for tenant $TenantId to '$path'."
    }
    catch {
        Write-Verbose "Could not save the connection profile for tenant $TenantId - auto-reconnect will not be available for it: $($_.Exception.Message)"
    }
}
