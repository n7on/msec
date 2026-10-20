#Requires -Module Pester
#
# Tests for Connect-MsecAzure.
#
# The traps:
#
#   IT DEFAULTS TO -Scope Process WHERE Connect-AzAccount DEFAULTS TO CurrentUser. Az's context
#   autosave writes the active context to the shared profile, so a sign-in in one shell becomes
#   the default for every shell opened afterwards.
#
#   THE macOS BROKER FAILURE NAMES NOTHING. "Interactive requests with mac broker enabled must
#   be executed on the main thread" says nothing about EnableLoginByWam, which is the fix.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
    $script:Stubbed = @()
    foreach ($c in 'Connect-AzAccount', 'Get-AzContext', 'Get-AzEnvironment') {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value {
                [CmdletBinding()] param($Subscription, $Tenant, $Environment, $Scope,
                                        [switch]$UseDeviceAuthentication, [switch]$ListAvailable)
            } -Force
            $script:Stubbed += $c
        }
    }
}
AfterAll {
    foreach ($c in $script:Stubbed) { Remove-Item "function:$c" -ErrorAction SilentlyContinue }
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Connect-MsecAzure' {

    BeforeEach {
        InModuleScope Msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Az.Accounts' } }
            Mock Import-Module -MockWith { }
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'PROD' }
                    Tenant       = [pscustomobject]@{ Id = 'tenant-1' }
                    Environment  = [pscustomobject]@{ Name = 'AzureCloud' }
                }
            }
        }
    }

    It 'keeps the sign-in in this shell by default' {
        # THE BUG THIS PREVENTS. Connect-AzAccount defaults to CurrentUser, which writes the
        # active context to ~/.Azure/AzureRmContext.json - so signing in here silently
        # re-points every shell opened afterwards.
        $scope = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { $script:SeenScope = $Scope }
            $null = Connect-MsecAzure
            $script:SeenScope
        }

        $scope | Should -Be 'Process'
    }

    It 'writes the shared profile only when asked' {
        $scope = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { $script:SeenScope = $Scope }
            $null = Connect-MsecAzure -Scope CurrentUser
            $script:SeenScope
        }

        $scope | Should -Be 'CurrentUser'
    }

    It 'names EnableLoginByWam when the macOS broker refuses the thread' {
        # The Azure error mentions the main thread and the broker but never the setting that
        # turns it off, which is the only thing a reader can act on.
        $msg = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith {
                throw 'InteractiveBrowserCredential authentication failed: Interactive requests with mac broker enabled must be executed on the main thread on macOS.'
            }
            try { Connect-MsecAzure | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*EnableLoginByWam*'
        $msg | Should -BeLike '*-UseDeviceCode*'
    }

    It 'does not blame the broker for an unrelated sign-in failure' {
        # Matching too eagerly would send someone to a config setting that is not their problem.
        $msg = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { throw 'AADSTS50076: Multi-factor authentication required.' }
            try { Connect-MsecAzure | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*AADSTS50076*'
        $msg | Should -Not -BeLike '*EnableLoginByWam*'
    }

    It 'passes the cloud through, since a sovereign tenant cannot be reached without it' {
        $seen = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { $script:SeenEnv = $Environment }
            $null = Connect-MsecAzure -Environment AzureChinaCloud
            $script:SeenEnv
        }

        $seen | Should -Be 'AzureChinaCloud'
    }

    It 'asks for a device code only when told to' {
        $seen = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { $script:SeenDev = [bool] $UseDeviceAuthentication }
            $null = Connect-MsecAzure
            $a = $script:SeenDev
            $null = Connect-MsecAzure -UseDeviceCode
            [pscustomobject]@{ Default = $a; Asked = $script:SeenDev }
        }

        $seen.Default | Should -BeFalse
        $seen.Asked   | Should -BeTrue
    }

    It 'reports which subscription the shell actually landed on' {
        # The question every Azure-plane command depends on, and the one the sign-in itself
        # does not answer clearly.
        $r = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { }
            Connect-MsecAzure
        }

        $r.Subscription   | Should -Be 'PROD'
        $r.SubscriptionId | Should -Be 'sub-1'
        $r.TenantId       | Should -Be 'tenant-1'
        $r.Environment    | Should -Be 'AzureCloud'
        $r.Scope          | Should -Be 'Process'
    }

    It 'completes the cloud from Get-AzEnvironment rather than a fixed list' {
        # NOT A ValidateSet ON PURPOSE. Add-AzEnvironment registers clouds Az does not ship
        # with, and an air-gapped or national cloud is exactly where this command is needed
        # most - a fixed list would complete nicely and then refuse a cloud that exists.
        #
        # MOCKED IN MODULE SCOPE. The completer scriptblock is defined in the module file, so
        # it resolves Get-AzEnvironment there - a function declared in the test's own scope
        # would be ignored and the real Az would answer.
        $r = InModuleScope Msec {
            Mock Get-AzEnvironment -MockWith {
                @([pscustomobject]@{ Name = 'AzureCloud';      ResourceManagerUrl = 'https://management.azure.com/' },
                  [pscustomobject]@{ Name = 'AzureChinaCloud'; ResourceManagerUrl = 'https://management.chinacloudapi.cn/' },
                  [pscustomobject]@{ Name = 'AirGapped';       ResourceManagerUrl = 'https://management.example.invalid/' })
            }
            $sb = (Get-Command Connect-MsecAzure).Parameters['Environment'].Attributes |
                      Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
                      ForEach-Object { $_.ScriptBlock }
            [pscustomobject]@{
                All    = @(& $sb 'Connect-MsecAzure' 'Environment' ''       $null @{}).CompletionText
                Narrow = @(& $sb 'Connect-MsecAzure' 'Environment' 'AzureC' $null @{}).CompletionText
            }
        }

        $r.All    | Should -Contain 'AirGapped'
        $r.Narrow | Should -Contain 'AzureChinaCloud'
        $r.Narrow | Should -Not -Contain 'AirGapped'
    }

    It 'completes nothing instead of erroring when Az cannot be asked' {
        # Completers run on every Tab. One that throws makes the shell look broken.
        $r = InModuleScope Msec {
            Mock Get-AzEnvironment -MockWith { throw 'Az is not available' }
            $sb = (Get-Command Connect-MsecAzure).Parameters['Environment'].Attributes |
                      Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
                      ForEach-Object { $_.ScriptBlock }
            [pscustomobject]@{
                Threw  = $(try { $null = & $sb 'Connect-MsecAzure' 'Environment' '' $null @{}; $false } catch { $true })
                Result = @(& $sb 'Connect-MsecAzure' 'Environment' '' $null @{})
            }
        }

        $r.Threw  | Should -BeFalse
        $r.Result | Should -BeNullOrEmpty
    }

    It 'leaves context population alone unless asked, and passes it through when asked' {
        # NOT LOWERED BY DEFAULT. Those populated contexts are what lets Set-MsecContext cross
        # clouds without a fresh sign-in, so quietly capping them would fix a slow sign-in by
        # breaking context switching.
        # ASSERTED WITH Should -Invoke, not by reading $PSBoundParameters inside the mock
        # body - that is empty there, which reads as "the parameter was never passed".
        InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { }

            $null = Connect-MsecAzure
            Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
                -not $PSBoundParameters.ContainsKey('MaxContextPopulation')
            }

            $null = Connect-MsecAzure -MaxContextPopulation 1
            Should -Invoke Connect-AzAccount -Times 1 -Exactly -ParameterFilter {
                $MaxContextPopulation -eq 1
            }
        }
    }

    It 'throws rather than reporting success when no context came back' {
        $msg = InModuleScope Msec {
            Mock Connect-AzAccount -MockWith { }
            Mock Get-AzContext -MockWith { $null }
            try { Connect-MsecAzure | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*did not complete*'
    }
}
