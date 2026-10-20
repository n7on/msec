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

    It 'refuses a tenant different from the one being read, without purging the sign-in' {
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

            # NO Disconnect-MgGraph. It clears the SDK's cached sign-in, which persists across
            # PowerShell sessions by design - purging it here meant every refused switch threw
            # away the credential the next one needed. msec's own gate is separate:
            # $script:MsecAdminSession is left null, so no Set-Msec* can run.
            Should -Invoke Disconnect-MgGraph -Times 0
            $script:MsecAdminSession | Should -BeNullOrEmpty
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

    It 'persists the write session by default, so a saved context can reuse it' {
        # WHAT THIS PREVENTS. With Process scope nothing is cached, so every Set-MsecContext
        # that moves a write session opens a browser - reported from a live session as
        # "it works until the admin context is logged in, then it needs auth every switch".
        # A named context exists to reuse connections that are already authenticated.
        #
        # Persisting the credential is NOT sharing the pointer: Get-MgContext is per process
        # and this command names the tenant and account explicitly, so two shells can hold
        # write sessions in two different tenants at once.
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
        # The opt-out, for "a person is at the keyboard now" rather than "somebody signed in
        # on this machine" - at the price of signing in again on every context switch.
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

    It 'signs in to the cloud the read session is on, not always Global' {
        # THE BUG THIS PREVENTS. Connect-MgGraph defaults to Global, whose authority is
        # login.microsoftonline.com. A China tenant id does not resolve there, so the sign-in
        # was rejected before any consent screen with nothing but
        # "InteractiveBrowserCredential authentication failed:" - no cloud named, no tenant
        # named. Connect-Msec and Connect-MsecGraphSdk were already cloud-aware; this was not.
        $env = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Get-MgEnvironment -MockWith {
                @([pscustomobject]@{ Name = 'Global'; GraphEndpoint = 'https://graph.microsoft.com' },
                  [pscustomobject]@{ Name = 'China';  GraphEndpoint = 'https://microsoftgraph.chinacloudapi.cn' })
            }
            Mock Connect-MgGraph -MockWith { $script:SeenEnv = $Environment }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.cn'; TenantId = 'tenant-cn'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-cn'
                                     Endpoints = @{ GraphResource = 'https://microsoftgraph.chinacloudapi.cn' } }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'
            $script:SeenEnv
        }

        $env | Should -Be 'China'
    }

    It 'leaves the environment alone on the commercial cloud' {
        # -Environment Global is the default, and passing it explicitly would make every
        # ordinary sign-in depend on Get-MgEnvironment resolving.
        $env = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Get-MgEnvironment -MockWith {
                @([pscustomobject]@{ Name = 'Global'; GraphEndpoint = 'https://graph.microsoft.com' })
            }
            Mock Connect-MgGraph -MockWith { $script:SeenEnv = $PSBoundParameters.ContainsKey('Environment') }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = @{ TenantId = 'tenant-1'
                                     Endpoints = @{ GraphResource = 'https://graph.microsoft.com' } }
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All'
            $script:SeenEnv
        }

        $env | Should -BeFalse
    }

    It 'assumes the commercial cloud when there is no read session to ask' {
        # Connect-MsecAdmin does not require Connect-Msec, so an unknown cloud must not warn
        # on every call - there is no better answer available.
        $warnings = InModuleScope msec {
            Mock Get-Module -ParameterFilter { $ListAvailable } -MockWith { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } }
            Mock Import-Module -MockWith { }
            Mock Get-MgEnvironment -MockWith { @() }
            Mock Connect-MgGraph -MockWith { }
            Mock Get-MgContext -MockWith {
                [pscustomobject]@{ Account = 'me@contoso.com'; TenantId = 'tenant-1'
                                   Scopes = @('SecurityAlert.ReadWrite.All') }
            }
            $script:MsecSession = $null
            $null = Connect-MsecAdmin -Scope 'SecurityAlert.ReadWrite.All' -WarningVariable w -WarningAction SilentlyContinue
            @($w).Count
        }

        $warnings | Should -Be 0
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
        # It must NOT tell the reader to run Disconnect-MgGraph as the routine fix - that
        # clears the cached sign-in and costs a full browser login next time.
        $w | Should -Not -Match 'Disconnect-MgGraph'
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

    It 'refuses a different account than asked for, without purging the sign-in' {
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

            # THE BUG THIS PREVENTS. Purging here destroyed the SDK's cached sign-in, so with
            # two identities across two tenants every switch tore down the credential it had
            # just created and the next switch needed the browser again - reported from a live
            # session as "I need to auth every time I change context".
            $script:DidDisconnect | Should -BeFalse
            # No write session was established, which is what actually keeps writes safe.
            $script:MsecAdminSession | Should -BeNullOrEmpty
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
