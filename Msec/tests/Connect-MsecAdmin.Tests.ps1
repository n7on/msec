#Requires -Module Pester
#
# Tests for Connect-MsecAdmin.
#
# This command exists because the app CANNOT write - every permission New-MsecApp consents is
# *.Read.All - so writes run as a person instead. Two things it must get right, both of which
# fail silently otherwise:
#
#   A declined scope is not an error. Connect-MgGraph returns a context without it and the
#   first write 403s naming nothing, so the granted set is checked against the requested one
#   here, while there is still something useful to say.
#
#   Signing in to a different tenant than Connect-Msec is reading is invisible at the time and
#   obvious afterwards. It is refused, and the half-open Graph session is closed on the way out.

BeforeAll {
    $script:StubbedGraphCommands = @()
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop

    # Microsoft.Graph.Authentication is NOT a dependency of msec - only Connect-MsecAdmin needs
    # it, and it checks at run time. It is preinstalled on the Windows and Ubuntu GitHub images
    # but NOT on the macOS one, so these tests passed on two runners and failed on the third:
    # Pester's Mock requires the command to EXIST, and a missing one fails as "Could not find
    # Command Get-MgContext" rather than as anything pointing at the real cause.
    #
    # Stubbed when absent OR unusable, so a machine with a working module still mocks the
    # real command and the two behave identically.
    # The stubs carry the REAL parameter names, not an empty param(). A -ParameterFilter is
    # evaluated against the mocked command's own signature, so a stub without -TenantId leaves
    # $TenantId unbound and the filter silently matches nothing - the mock is invoked, the
    # assertion counts zero calls, and the failure looks like the command was never called.
    $graphStubs = @{
        'Get-MgContext'      = { [CmdletBinding()] param() }
        'Disconnect-MgGraph' = { [CmdletBinding()] param() }
        'Connect-MgGraph'    = {
            [CmdletBinding()]
            param(
                [string[]] $Scopes,
                [string]   $TenantId,
                [switch]   $NoWelcome,
                           $AccessToken,
                [string]   $Environment,
                # The stub must carry every parameter the command passes, or the call fails
                # to bind HERE and nowhere else - on a machine with the real Graph SDK
                # installed the stub is never used and the same test passes.
                [string]   $ContextScope
            )
        }
    }
    foreach ($graphCmd in $graphStubs.Keys) {
        # DISCOVERABLE IS NOT USABLE, and testing only for presence is what broke CI on the
        # ubuntu runner: Get-MgContext resolved as a command while its backing assembly
        # (Microsoft.Graph.Authentication.Core) could not be loaded, so the stub was skipped
        # and Pester's Mock then died building CommandMetadata -
        #   "Cannot convert value Get-MgContext to type CommandMetadata"
        # which points at the mock rather than at the half-installed module behind it. So the
        # probe is the same one Mock performs: build the metadata, and stub when that fails.
        # A global function shadows a cmdlet of the same name, so the stub wins either way.
        $usable = $false
        $found  = Get-Command $graphCmd -ErrorAction SilentlyContinue
        if ($found) {
            try   { $null = [System.Management.Automation.CommandMetadata]::new($found); $usable = $true }
            catch { $usable = $false }
        }
        if (-not $usable) {
            Set-Item "function:global:$graphCmd" -Value $graphStubs[$graphCmd] -Force
            $script:StubbedGraphCommands += $graphCmd
        }
    }
}
AfterAll {
    foreach ($graphCmd in $script:StubbedGraphCommands) {
        Remove-Item "function:global:$graphCmd" -ErrorAction SilentlyContinue
    } Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Connect-MsecAdmin' {

    It 'refuses when the tenant granted fewer scopes than were asked for' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            # Asked for two, granted one - which Connect-MgGraph reports as success.
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 't1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = $null

            { Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All', 'SecurityIncident.ReadWrite.All' } |
                Should -Throw '*SecurityIncident.ReadWrite.All*'
        }
    }

    It 'refuses a tenant different from the one being read, and closes the session' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Disconnect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'OTHER-TENANT'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            # Reading tenant-1; the sign-in landed somewhere else.
            $script:MsecSession = @{ TenantId = 'tenant-1' }

            { Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -TenantId 'OTHER-TENANT' } |
                Should -Throw '*different tenant*'
            # The half-open session must not be left behind for a later command to find.
            Should -Invoke Disconnect-MgGraph -Times 1 -Exactly
        }
    }

    It 'defaults to the tenant Connect-Msec is reading' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }

            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'

            Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter { $TenantId -eq 'tenant-1' }
        }
    }

    It 'records the write session separately from the read session' {
        $session = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'
            # A Set-* has to tell "no write session" from "app session" - so they are distinct.
            $script:MsecAdminSession
        }

        $session.Account      | Should -Be 'me@contoso.com'
        $session.GrantedScope | Should -Contain 'SecurityAlert.ReadWrite.All'
    }

    It 'names the module to install when the Graph SDK is absent' {
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { $null }
            { Connect-MsecAdmin } | Should -Throw '*Microsoft.Graph.Authentication*'
        }
    }

    It 'persists the session by default, matching Connect-Msec' {
        # THE BUG THIS PREVENTS. Connect-MgGraph defaults to Process scope, so the token lived
        # in the shell that signed in: the read session worked in every process and the write
        # session worked in exactly one, with a zero-byte MSAL cache file as the only clue.
        # The two connect commands have to behave the same way, or the difference surfaces as
        # "the admin session is not being seen".
        #
        # Import-Module IS MOCKED, like the test above. Letting the real
        # Microsoft.Graph.Authentication load changes how Get-MgEnvironment resolves for the
        # rest of the run, which breaks Connect-MsecGraphSdk's tests in another file and only
        # in a full-suite run.
        $scope = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { $script:SeenScope = $ContextScope }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'
            $script:SeenScope
        }

        $scope | Should -Be 'CurrentUser'
    }

    It 'keeps the token in this shell only when asked' {
        # The escape hatch for "a person is at the keyboard now" rather than "a person signed
        # in once on this machine".
        $scope = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { $script:SeenScope = $ContextScope }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -ContextScope Process
            $script:SeenScope
        }

        $scope | Should -Be 'Process'
    }

    It 'rejects a context scope Connect-MgGraph would not understand' {
        InModuleScope msec {
            { Connect-MsecAdmin -ContextScope Machine } | Should -Throw
        }
    }

    It 'names the exact scopes it asks for, so a consent request can quote them' {
        # "Which scopes does it actually ask for?" was the first question asked when consent
        # was refused, and the only way to answer it was to read the source.
        $v = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All', 'User.Read', 'openid') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            # Verbose is stream 4.
            (Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                ForEach-Object { $_.Message }) -join ' '
        }

        $v | Should -Match 'Requesting 1 delegated scope'
        $v | Should -Match 'SecurityAlert\.ReadWrite\.All'
        # The token's own list is larger and means something different - consent history,
        # not what this command asked for.
        $v | Should -Match 'Token carries 3 scope'
    }

    It 'warns when the sign-in lands on a different account than last time' {
        # THE FAILURE THIS NAMES. Connect-MgGraph has no -Account parameter, so the browser
        # reuses whichever identity it remembers. With two tenants and two identities that
        # silently picks the wrong one, and the error surfaces later as AADSTS500213 - a
        # cross-tenant policy message that says nothing about the account being wrong.
        $w = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Save-MsecTenantProfile -MockWith { }
            Mock Get-MsecTenantProfile -MockWith {
                [pscustomobject]@{ TenantId='tenant-1'; KeyVaultName='kv'; ClientId='cid'
                                   CertificateName='msec-app'; AdminAccount='someone.else@contoso.com' }
            }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            "$wv"
        }

        $w | Should -Match 'someone\.else@contoso\.com'
        $w | Should -Match 'Disconnect-MgGraph'
    }

    It 'records the account it signed in as, so the next sign-in can compare' {
        $saved = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MsecTenantProfile -MockWith {
                [pscustomobject]@{ TenantId='tenant-1'; KeyVaultName='kv'; ClientId='cid'; CertificateName='msec-app' }
            }
            Mock Save-MsecTenantProfile -MockWith { $script:SavedAccount = $AdminAccount }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' | Out-Null
            $script:SavedAccount
        }

        $saved | Should -Be 'me@contoso.com'
    }

    It 'refuses, and closes the session, when the sign-in lands on a different account than asked for' {
        # THE POINT OF -Account. Connect-MgGraph cannot pick an identity, so the browser does -
        # and it reuses whichever it remembers. Being told afterwards is no use once a Set-*
        # has run against the wrong tenant, so this throws and disconnects rather than warning.
        InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Disconnect-MgGraph -MockWith { $script:DidDisconnect = $true }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'wrong@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            $script:DidDisconnect = $false

            { Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -Account 'right@contoso.com' } |
                Should -Throw '*right@contoso.com*wrong@contoso.com*'

            # Left connected as the wrong identity would be worse than failing.
            $script:DidDisconnect | Should -BeTrue
        }
    }

    It 'accepts the session when the account matches what was asked for' {
        $acct = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MsecTenantProfile -MockWith { $null }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'right@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            (Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -Account 'right@contoso.com').Account
        }

        $acct | Should -Be 'right@contoso.com'
    }

    It 'warns rather than throws about a changed account when none was asked for' {
        # -Account is an assertion. Without one, the recorded account is only a hint, so a
        # difference is worth saying and not worth refusing over.
        $w = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Connect-MgGraph -MockWith { }
            Mock Save-MsecTenantProfile -MockWith { }
            Mock Get-MsecTenantProfile -MockWith {
                [pscustomobject]@{ TenantId='tenant-1'; KeyVaultName='kv'; ClientId='cid'
                                   CertificateName='msec-app'; AdminAccount='someone.else@contoso.com' }
            }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1' }
            Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            "$wv"
        }

        $w | Should -Match 'someone\.else@contoso\.com'
    }
}
