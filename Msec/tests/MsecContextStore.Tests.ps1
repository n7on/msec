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
#
#   AZURE NEEDS A SEPARATE SIGN-IN PER CLOUD, and Set-AzContext -Subscription/-Tenant resolves
#   the subscription INSIDE THE CURRENT ACCOUNT. Signed in to one cloud, switching to a context
#   in another failed with "Please provide a valid tenant or a valid subscription" while the
#   target context sat in Az's own cache, fully usable.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
    $script:CacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("msec-ctx-" + [guid]::NewGuid())
    $env:MSEC_CACHE_DIR = $script:CacheDir
    $script:StubbedAz = @()
    foreach ($c in 'Get-AzContext', 'Set-AzContext') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value { [CmdletBinding()] param($Subscription, $Tenant, $Context, $Scope, [switch]$ListAvailable) } -Force
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
                    Environment  = [pscustomobject]@{ Name = 'AzureCloud' }
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

    It 'selects a cached context rather than resolving inside the current account' {
        # THE BUG THIS PREVENTS. Set-AzContext -Subscription/-Tenant resolves the subscription
        # inside the CURRENT account, so switching from a context in one cloud to a context in
        # another failed - "Please provide a valid tenant or a valid subscription" - while the
        # target context was already in Az's cache and perfectly usable. A cached context
        # carries its own account and environment, so selecting it crosses clouds.
        InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith {
                @([pscustomobject]@{
                    Name         = 'DEV'
                    Account      = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Subscription = [pscustomobject]@{ Id = 'sub-dev'; Name = 'DEV' }
                    Tenant       = [pscustomobject]@{ Id = 'tenant-dev' }
                    Environment  = [pscustomobject]@{ Name = 'AzureCloud' }
                })
            }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.cn' }
                    Subscription = [pscustomobject]@{ Id = 'sub-cn'; Name = 'CHINA' }
                    Environment  = [pscustomobject]@{ Name = 'AzureChinaCloud' }
                }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }

            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload | Out-Null

            # ASSERTED ON WHICH PARAMETER SET WAS USED, not on the object handed over.
            # -Context is typed [PSAzureContext], so a [pscustomobject] stand-in is COERCED
            # into that type on binding and the properties set here do not survive - an
            # assertion on $Context.Name tests the coercion, not the code.
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $null -ne $Context }
            Should -Invoke Set-AzContext -Times 0 -ParameterFilter { $null -ne $Subscription }
        }
    }

    It 'names the cloud and the sign-in needed when the switch fails across clouds' {
        # The Az error never mentions the cloud, which is the entire explanation.
        $msg = InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.cn' }
                    Subscription = [pscustomobject]@{ Id = 'sub-cn'; Name = 'CHINA' }
                    Environment  = [pscustomobject]@{ Name = 'AzureChinaCloud' }
                }
            }
            Mock Set-AzContext -MockWith { throw 'Please provide a valid tenant or a valid subscription.' }

            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            try { Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload | Out-Null }
            catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*AzureCloud cloud*'
        $msg | Should -BeLike '*AzureChinaCloud*'
        $msg | Should -BeLike '*Connect-AzAccount -Environment AzureCloud*'
    }

    It 'says nothing about clouds for a context saved before the cloud was recorded' {
        # Older saved contexts have no Environment. Guessing one would be worse than silence.
        $msg = InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                    Environment  = [pscustomobject]@{ Name = 'AzureCloud' }
                }
            }
            Mock Set-AzContext -MockWith { throw 'Please provide a valid tenant or a valid subscription.' }

            Write-MsecContextStore @{ old = [pscustomobject]@{
                Name = 'old'; SubscriptionId = 'sub-old'; Subscription = 'OLD'
                TenantId = 'tenant-old'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            try { Set-MsecContext -Name 'old' -Confirm:$false -KeepWorkload | Out-Null }
            catch { $_.Exception.Message }
        }

        $msg | Should -Not -BeLike '*Connect-AzAccount -Environment*'
    }

    It 'switches this shell only, not every shell opened afterwards' {
        # Az's context autosave writes the active context to the shared profile, so without a
        # scope the switch follows you into every new terminal. The app session and the write
        # session already die with the shell; this was the one that did not.
        InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }

            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload | Out-Null
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $Scope -eq 'Process' }

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload -Scope CurrentUser | Out-Null
            Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $Scope -eq 'CurrentUser' }
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

    It 'does not prompt when the write session is already on the target tenant' {
        # THE BUG THIS PREVENTS. With Connect-MsecAdmin scoped to the process there is no
        # cached refresh token, so calling it again means a browser prompt. Re-selecting a
        # context you are already on must not open a browser.
        InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Connect-MsecAdmin -MockWith { }
            Mock Disconnect-MgGraph -MockWith { }

            $script:MsecAdminSession = [pscustomobject]@{ Account = 'admin@contoso.com'; TenantId = 'tenant-dev' }
            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'; AdminAccount = 'admin@contoso.com'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload | Out-Null

            Should -Invoke Connect-MsecAdmin -Times 0
            Should -Invoke Disconnect-MgGraph -Times 0
            $script:MsecAdminSession | Should -Not -BeNullOrEmpty
        }
    }

    It 'disconnects a write session belonging to a tenant you just left' {
        # Leaving it in place is the dangerous case - it would go on accepting writes aimed at
        # the old tenant. Carrying it over is not possible without a browser, because the Graph
        # SDK has no context store and no way to name a cached identity, so it is dropped and
        # -Admin signs back in when a write is actually intended.
        $w = InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Connect-MsecAdmin -MockWith { }
            Mock Disconnect-MgGraph -MockWith { }

            $script:MsecAdminSession = [pscustomobject]@{ Account = 'admin@contoso.com'; TenantId = 'tenant-prod' }
            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'; AdminAccount = 'admin@contoso.com'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload -WarningVariable wv -WarningAction SilentlyContinue | Out-Null

            Should -Invoke Connect-MsecAdmin -Times 0
            Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
            [pscustomobject]@{ Session = $script:MsecAdminSession; Warning = ($wv -join ' ') }
        }

        $w.Session | Should -BeNullOrEmpty
        $w.Warning | Should -BeLike '*-Admin*'
    }

    It 'signs in as the account the context records when -Admin is passed' {
        # -Admin IS the request for a browser. The account is passed through so a sign-in
        # landing on whichever identity the browser remembers is refused, not written with.
        InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Connect-MsecAdmin -MockWith { }
            Mock Disconnect-MgGraph -MockWith { }

            $script:MsecAdminSession = [pscustomobject]@{ Account = 'old@contoso.com'; TenantId = 'tenant-prod' }
            Write-MsecContextStore @{ dev = [pscustomobject]@{
                Name = 'dev'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'; AdminAccount = 'admin@contoso.com'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'dev' -Confirm:$false -KeepWorkload -Admin | Out-Null

            Should -Invoke Connect-MsecAdmin -Times 1 -Exactly -ParameterFilter {
                $TenantId -eq 'tenant-dev' -and $Account -eq 'admin@contoso.com'
            }
            Should -Invoke Disconnect-MgGraph -Times 0
        }
    }

    It 'drops a write session even when the context records no admin account' {
        # A context with no admin account cannot say who to sign in as - which is all the more
        # reason not to leave the old session pointed at the tenant you just left.
        $w = InModuleScope Msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' }
                                   Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                                   Environment = [pscustomobject]@{ Name = 'AzureCloud' } }
            }
            Mock Set-AzContext -MockWith { }
            Mock Connect-Msec -MockWith { }
            Mock Connect-MsecAdmin -MockWith { }

            $script:MsecAdminSession = [pscustomobject]@{ Account = 'admin@contoso.com'; TenantId = 'tenant-prod' }
            Write-MsecContextStore @{ bare = [pscustomobject]@{
                Name = 'bare'; SubscriptionId = 'sub-dev'; Subscription = 'DEV'
                TenantId = 'tenant-dev'; Environment = 'AzureCloud'
                KeyVaultName = 'kv'; ClientId = 'cid'; CertificateName = 'cert' } } | Out-Null

            Set-MsecContext -Name 'bare' -Confirm:$false -KeepWorkload -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            Should -Invoke Connect-MsecAdmin -Times 0
            ($wv -join ' ')
        }

        $w | Should -BeLike '*disconnected*'
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
