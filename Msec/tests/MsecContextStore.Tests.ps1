#Requires -Module Pester
#
# Tests for Save- / Set- / Remove-MsecContext and the store behind them.
#
# The traps:
#
#   THE SESSION DOES NOT CARRY THE CERTIFICATE NAME. It holds the Key Vault KEY name resolved
#   from the certificate's metadata - a different thing, and not what Connect-Msec takes.
#   Saving $session.CertificateName silently recorded an empty string, and the reconnect then
#   failed on parameter binding. The tenant profile is where that name lives.
#
#   WORKLOAD SESSIONS CANNOT BE RE-POINTED, ONLY TORN DOWN. Left alone across a tenant switch
#   they keep working against the tenant you left, which is worse than being disconnected.
#
#   A FAILED RECONNECT MUST NOT UNDO THE SWITCH. The context change is what was asked for.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
    $script:CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("msec-ctx-" + [guid]::NewGuid())
    $env:MSEC_CACHE_DIR = $script:CacheDir
    $script:StubbedAz = @()
    foreach ($c in 'Get-AzContext', 'Set-AzContext') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value { [CmdletBinding()] param($Subscription, $Tenant) } -Force
            $script:StubbedAz += $c
        }
    }
    # Pester's Mock needs the command to EXIST. The workload disconnects live in modules that
    # are not dependencies of msec, so on a runner without them the mock fails to build and
    # the test reads as a bug in the code rather than a missing module.
    foreach ($c in 'Disconnect-ExchangeOnline', 'Disconnect-MicrosoftTeams', 'Disconnect-PnPOnline') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value { [CmdletBinding()] param([switch]$Confirm) } -Force
            $script:StubbedAz += $c
        }
    }
}
AfterAll {
    Remove-Item $script:CacheDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:MSEC_CACHE_DIR -ErrorAction SilentlyContinue
    foreach ($c in $script:StubbedAz) { Remove-Item "function:$c" -ErrorAction SilentlyContinue }
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Save-MsecContext' {

    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv'
                                     KeyName = 'msec-app-key' }
            $script:MsecAdminSession = $null
        }
    }

    It 'takes the certificate name from the tenant profile, not from the session' {
        # REGRESSION. The session has KeyName, not CertificateName; reading the latter saved an
        # empty string and Set-MsecContext then failed binding -CertificateName.
        $saved = InModuleScope Msec {
            Mock Get-MsecTenantProfile -MockWith {
                [pscustomobject]@{ CertificateName = 'from-profile'; KeyVaultName = 'kv'; ClientId = 'cid' }
            }
            Save-MsecContext -Name 'ctx-cert' -Force
        }

        $saved.CertificateName | Should -Be 'from-profile'
        $saved.CertificateName | Should -Not -BeNullOrEmpty
    }

    It 'records no admin account when there is no write session, which means "does not write"' {
        $saved = InModuleScope Msec {
            Mock Get-MsecTenantProfile -MockWith { $null }
            Save-MsecContext -Name 'ctx-noadmin' -Force
        }

        $saved.AdminAccount | Should -BeNullOrEmpty
    }

    It 'captures the live write session account by default' {
        $saved = InModuleScope Msec {
            Mock Get-MsecTenantProfile -MockWith { $null }
            $script:MsecAdminSession = [pscustomobject]@{ Account = 'admin@contoso.com'; TenantId = 'tenant-1' }
            Save-MsecContext -Name 'ctx-admin' -Force
        }

        $saved.AdminAccount | Should -Be 'admin@contoso.com'
    }

    It 'refuses to save without an app session, naming what to run' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Save-MsecContext -Name 'nope' -Force } | Should -Throw '*Connect-Msec -KeyVaultName*'
        }
    }

    It 'round-trips through the store and can be removed' {
        $r = InModuleScope Msec {
            Mock Get-MsecTenantProfile -MockWith { $null }
            Save-MsecContext -Name 'ctx-rt' -Force | Out-Null
            $listed = @(Get-MsecContext -List | Where-Object Name -eq 'ctx-rt')
            Remove-MsecContext -Name 'ctx-rt' -Confirm:$false
            [pscustomobject]@{ Listed = $listed.Count
                               After  = @(Get-MsecContext -List | Where-Object Name -eq 'ctx-rt').Count }
        }

        $r.Listed | Should -Be 1
        $r.After  | Should -Be 0
    }
}

Describe 'Set-MsecContext' {

    It 'throws, naming how to list them, for a context that does not exist' {
        InModuleScope Msec {
            { Set-MsecContext -Name 'no-such-context' -Confirm:$false } |
                Should -Throw '*Get-MsecContext -List*'
        }
    }

    It 'keeps the switch when the app session fails to reconnect' {
        # The context change is what was asked for; losing a session is reported, not undone.
        $w = InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Tenant = [pscustomobject]@{ Id = 'tenant-1' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Connect-Msec -MockWith { throw 'vault unreachable' }
            Mock Get-Module -MockWith { $null }
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = $null
            Save-MsecContext -Name 'ctx-fail' -Force | Out-Null

            Set-MsecContext -Name 'ctx-fail' -Confirm:$false -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            "$wv"
        }

        $w | Should -Match 'did not reconnect'
        $w | Should -Match 'vault unreachable'
    }

    It 'does not start a write session that was not already there' {
        # Signing in is interactive, and a prompt in the middle of a context switch is a surprise.
        $called = InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Tenant = [pscustomobject]@{ Id = 'tenant-1' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Get-Module -MockWith { $null }
            $script:AdminCalls = 0
            Mock Connect-MsecAdmin -MockWith { $script:AdminCalls++ }
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = $null
            Save-MsecContext -Name 'ctx-noauto' -AdminAccount 'admin@contoso.com' -Force | Out-Null

            Set-MsecContext -Name 'ctx-noauto' -Confirm:$false | Out-Null
            $script:AdminCalls
        }

        $called | Should -Be 0
    }

    It 'disconnects workload sessions it cannot re-point' {
        # Left alone they keep answering for the tenant you just left.
        $dropped = InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Tenant = [pscustomobject]@{ Id = 'tenant-1' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Get-Module -MockWith { [pscustomobject]@{ Name = 'ExchangeOnlineManagement' } } `
                 -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
            Mock Get-Module -MockWith { $null }
            $script:Dropped = $false
            Mock Get-Command -MockWith { [pscustomobject]@{ Name = 'Disconnect-ExchangeOnline' } } `
                 -ParameterFilter { $Name -eq 'Disconnect-ExchangeOnline' }
            Mock Disconnect-ExchangeOnline -MockWith { $script:Dropped = $true }
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = $null
            Save-MsecContext -Name 'ctx-wl' -Force | Out-Null

            Set-MsecContext -Name 'ctx-wl' -Confirm:$false | Out-Null
            $script:Dropped
        }

        $dropped | Should -BeTrue
    }
}
