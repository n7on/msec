#Requires -Module Pester
#
# Tests for Get-MsecContext.
#
# The traps:
#
#   A STALE SESSION IS THE FAILURE, NOT A MISSING ONE. An absent session fails loudly; one
#   left on the tenant you switched away from SUCCEEDS and returns the wrong tenant's data.
#   The Aligned column is the reason the command exists, so it is what these tests cover.
#
#   "NOT CONNECTED" AND "CANNOT TELL" MUST NOT COLLAPSE. ModuleNotLoaded and Unknown exist so
#   that "I did not look" never renders as "there is nothing there" - which is precisely what
#   would hide a stale session.
#
#   THE GRAPH SDK AND THE WRITE SESSION SHARE Get-MgContext, told apart by AuthType. Reading
#   one result as both would report a write session that does not exist.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
    $script:StubbedAz = @()
    $stubs = @{
        'Get-AzContext'   = { [CmdletBinding()] param() }
        # Mocked by the app-only-vs-write-session test. Not a dependency of msec, and NOT
        # installed on the CI runners.
        'Get-MgContext'   = { [CmdletBinding()] param() }
    }
    foreach ($c in $stubs.Keys) {
        # DISCOVERABLE IS NOT USABLE. On the ubuntu and windows runners Get-MgContext RESOLVES
        # as a command - the module manifest is there - while its backing assembly
        # (Microsoft.Graph.Authentication.Core) cannot be loaded. A presence check therefore
        # skips the stub, and Pester's Mock then dies building CommandMetadata:
        #   "Cannot convert value Get-MgContext to type CommandMetadata"
        # which points at the mock rather than at the half-installed module behind it. macOS
        # has the module properly installed, so this passes locally and fails only in CI.
        # Same probe Mock performs: build the metadata, and stub when that fails.
        $usable = $false
        $found  = Get-Command $c -ErrorAction SilentlyContinue
        if ($found) {
            try   { $null = [System.Management.Automation.CommandMetadata]::new($found); $usable = $true }
            catch { $usable = $false }
        }
        if (-not $usable) {
            Set-Item "function:global:$c" -Value $stubs[$c] -Force
            $script:StubbedAz += $c
        }
    }
}
AfterAll {
    foreach ($c in $script:StubbedAz) { Remove-Item "function:$c" -ErrorAction SilentlyContinue }
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecContext' {

    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'me@contoso.com' }
                    Tenant       = [pscustomobject]@{ Id = 'tenant-1' }
                    Subscription = [pscustomobject]@{ Name = 'PROD' }
                }
            }
        }
    }

    It 'flags a session bound to a different tenant than the Azure context' {
        # THE WHOLE POINT. Get-EXOMailbox against last tenant's connection does not complain -
        # it returns correct-looking data from the wrong place.
        $rows = InModuleScope Msec {
            $script:MsecSession      = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = [pscustomobject]@{ Account = 'admin@contoso.com'
                                                          TenantId = 'OTHER-TENANT'; GrantedScope = @('a','b') }
            Get-MsecContext
        }

        ($rows | Where-Object Surface -eq 'App (Connect-Msec)').Aligned        | Should -Be 'Aligned'
        ($rows | Where-Object Surface -like 'Write*').Aligned                  | Should -Be 'DIFFERENT'
        ($rows | Where-Object Surface -like 'Write*').TenantId                 | Should -Be 'OTHER-TENANT'
    }

    It 'reports a module that is not loaded as such, not as "not connected"' {
        # "I did not look" and "there is nothing there" are different answers, and conflating
        # them is what makes a stale session invisible.
        $rows = InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = $null
            Mock Get-Module -MockWith { $null }
            Get-MsecContext -IncludeWorkload
        }

        $exo = $rows | Where-Object Surface -eq 'Exchange Online'
        $exo.Status | Should -Be 'ModuleNotLoaded'
        $exo.Status | Should -Not -Be 'NotConnected'
    }

    It 'never reports Teams as connected or disconnected, because it cannot cheaply tell' {
        # Get-CsTenant is a round trip. A command built to end guesses about session state
        # must not make one itself.
        $teams = InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            Mock Get-Module -MockWith { [pscustomobject]@{ Name = 'MicrosoftTeams' } } -ParameterFilter { $Name -eq 'MicrosoftTeams' }
            Mock Get-Module -MockWith { $null }
            (Get-MsecContext -IncludeWorkload | Where-Object Surface -eq 'Teams')
        }

        $teams.Status | Should -Be 'Unknown'
    }

    It 'does not claim a write session from an app-only Graph context' {
        # Both read Get-MgContext; AuthType is the only thing separating them.
        $rows = InModuleScope Msec {
            $script:MsecSession      = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            $script:MsecAdminSession = $null
            Mock Get-Module -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } } `
                 -ParameterFilter { $Name -eq 'Microsoft.Graph.Authentication' }
            Mock Get-Module -MockWith { $null }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ AuthType = 'AppOnly'; ClientId = 'cid'; TenantId = 'tenant-1' }
            }
            Get-MsecContext -IncludeWorkload
        }

        ($rows | Where-Object Surface -like 'Write*').Status      | Should -Be 'NotConnected'
        ($rows | Where-Object Surface -like 'Graph SDK*').Status  | Should -Be 'Connected'
    }

    It 'omits the workload rows unless asked, because probing costs other modules' {
        $rows = InModuleScope Msec {
            $script:MsecSession = @{ TenantId = 'tenant-1'; ClientId = 'cid'; KeyVaultName = 'kv' }
            Get-MsecContext
        }

        @($rows).Count | Should -Be 3
        @($rows.Surface) | Should -Not -Contain 'Exchange Online'
    }
}
