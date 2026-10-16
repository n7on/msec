#Requires -Module Pester
#
# Tests for the tenant connection profile - what makes switching Azure context also reconnect
# the msec app session.
#
# The point of the feature is that msec runs on TWO identities: the Az context is you, the
# msec session is the app registration. Switching one used to leave the other pointing at the
# tenant you just left, so every Graph call kept answering for the wrong tenant and all you
# got was a warning.
#
# What must hold:
#   * a profile stores CONFIGURATION only - vault, client id, cert name. No secret, because
#     there isn't one: signing happens inside Key Vault and the private key never leaves it.
#   * profiles are per tenant and can never overwrite each other
#   * a missing, unreadable or incomplete profile is silently "no profile", never an error in
#     the middle of a context switch
#   * a failed reconnect must not fail the context switch that was actually asked for

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) "msec-profile-$([guid]::NewGuid().Guid)"
    $env:MSEC_CACHE_DIR = $script:CacheDir
}

AfterAll {
    Remove-Item env:MSEC_CACHE_DIR -ErrorAction SilentlyContinue
    if ($script:CacheDir -and (Test-Path $script:CacheDir)) {
        Remove-Item $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'tenant connection profile' {

    It 'round-trips, and keeps tenants apart' {
        InModuleScope Msec {
            Save-MsecTenantProfile -TenantId 'tenant-a' -KeyVaultName 'kv-a' -ClientId 'client-a'
            Save-MsecTenantProfile -TenantId 'tenant-b' -KeyVaultName 'kv-b' -ClientId 'client-b' -CertificateName 'other-cert'

            $a = Get-MsecTenantProfile -TenantId 'tenant-a'
            $b = Get-MsecTenantProfile -TenantId 'tenant-b'

            $a.KeyVaultName    | Should -Be 'kv-a'
            $a.ClientId        | Should -Be 'client-a'
            $a.CertificateName | Should -Be 'msec-app'      # the default, recorded explicitly

            # Saving B must not have touched A - the whole reason profiles are per-tenant
            # folders rather than one shared file.
            $b.KeyVaultName    | Should -Be 'kv-b'
            $b.CertificateName | Should -Be 'other-cert'
            $a.KeyVaultName    | Should -Be 'kv-a'
        }
    }

    It 'stores no secret' {
        InModuleScope Msec {
            Save-MsecTenantProfile -TenantId 'tenant-nokeys' -KeyVaultName 'kv' -ClientId 'client'
            $raw = Get-Content -LiteralPath (Get-MsecCachePath -Name 'profile' -TenantId 'tenant-nokeys') -Raw

            # Signing happens inside Key Vault, so there is nothing secret to leak here - but
            # a future change that started caching key material would be a real problem, and
            # this is where it would show up.
            $raw | Should -Not -Match '(?i)privatekey|thumbprint|secret|password|-----BEGIN'
        }
    }

    It 'treats a missing, malformed or incomplete profile as no profile' {
        InModuleScope Msec {
            Get-MsecTenantProfile -TenantId 'tenant-never-seen' | Should -BeNullOrEmpty

            # Hand-edited into nonsense.
            $path = Get-MsecCachePath -Name 'profile' -TenantId 'tenant-broken'
            New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value '{ not json at all'
            Get-MsecTenantProfile -TenantId 'tenant-broken' | Should -BeNullOrEmpty

            # Valid JSON, but without what Connect-Msec needs - e.g. written by an older
            # version. Ignored rather than turned into a failure mid-switch.
            $path = Get-MsecCachePath -Name 'profile' -TenantId 'tenant-partial'
            New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value '{ "TenantId": "tenant-partial" }'
            Get-MsecTenantProfile -TenantId 'tenant-partial' | Should -BeNullOrEmpty
        }
    }

    It 'never fails the caller when it cannot be saved' {
        InModuleScope Msec {
            Mock Set-Content -MockWith { throw 'read-only volume' }
            # Losing auto-reconnect must not cost the session that just connected.
            { Save-MsecTenantProfile -TenantId 'tenant-ro' -KeyVaultName 'kv' -ClientId 'c' } |
                Should -Not -Throw
        }
    }
}

Describe 'Set-MsecContext reconnect' {

    BeforeEach {
        InModuleScope Msec { $script:MsecSession = $null }
    }

    # The four auto-reconnect tests that used to live here went with Set-MsecContext.
    # That command carried the "switch context, app session follows" behaviour; Set-MsecContext
    # replaces it and is covered by MsecContextStore.Tests.ps1. The profile itself remains -
    # Connect-MsecAdmin reads the admin account from it, Save-MsecContext the certificate name.
}
