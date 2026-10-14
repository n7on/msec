BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psd1') -Force

    # Defined here, not in the Describe body: a variable set at discovery time is gone by the
    # time an It runs, which reads as the command returning nothing rather than as a test bug.
    $policy = @{
        authenticationMethodConfigurations = @(
            @{ id = 'Fido2'; state = 'enabled'; isSelfServiceRegistrationAllowed = $true
               includeTargets = @(@{ id = 'g-break-glass'; targetType = 'group' }) }
            @{ id = 'MicrosoftAuthenticator'; state = 'enabled'
               includeTargets = @(@{ id = 'all_users'; targetType = 'group' })
               excludeTargets = @(@{ id = 'g-break-glass'; targetType = 'group' }) }
            @{ id = 'Sms'; state = 'enabled'
               includeTargets = @(@{ id = 'all_users'; targetType = 'group' }) }
            @{ id = 'TemporaryAccessPass'; state = 'disabled'
               includeTargets = @(@{ id = 'all_users'; targetType = 'group' }) }
            @{ id = 'X509Certificate'; state = 'disabled'
               includeTargets = @(@{ id = 'all_users'; targetType = 'group' }) }
        )
    }
}

Describe 'Get-MsecEntraAuthenticationMethod' {

    BeforeEach {
        InModuleScope msec { Mock Assert-MsecSession {} }
    }

    It 'reports an enabled method scoped to one group as NOT available to all users' {
        # The entire point of the command. Fido2 reads 'enabled' and a report that stopped at
        # the state column would credit this tenant with having FIDO2, when two accounts can
        # use it. State and reach are different questions and the command answers both.
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'Emergency-Access-Accounts' }
            }
            $fido = Get-MsecEntraAuthenticationMethod | Where-Object Method -eq 'Fido2'
            $fido.State               | Should -Be 'enabled'
            $fido.AvailableToAllUsers | Should -BeFalse
            $fido.IncludeTarget       | Should -Be @('Emergency-Access-Accounts')
        }
    }

    It 'treats the all_users sentinel as everyone without looking it up as a group' {
        # all_users is a built-in token, not a directory object: a lookup 404s. Resolving it to
        # the literal string 'all_users' would also read as a group name in the output.
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                if ($Path -like '*all_users*') { throw 'Request_ResourceNotFound' }
                return @{ displayName = 'Emergency-Access-Accounts' }
            }
            $sms = Get-MsecEntraAuthenticationMethod | Where-Object Method -eq 'Sms'
            $sms.AvailableToAllUsers | Should -BeTrue
            $sms.IncludeTarget       | Should -Be @('All users')
        }
    }

    It 'does not call AvailableToAllUsers true for a disabled method targeted at everyone' {
        # TemporaryAccessPass ships targeted at all users and switched off. Reading the target
        # alone would report it as available tenant-wide; reading the state alone would lose
        # that it is ready to turn on. Both are needed, and AvailableToAllUsers is the AND.
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            $tap = Get-MsecEntraAuthenticationMethod | Where-Object Method -eq 'TemporaryAccessPass'
            $tap.State               | Should -Be 'disabled'
            $tap.AvailableToAllUsers | Should -BeFalse
            $tap.IncludeTarget       | Should -Be @('All users')
        }
    }

    It 'returns disabled methods so "turned off" stays distinct from "does not exist"' {
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            $all = Get-MsecEntraAuthenticationMethod
            $all.Count | Should -Be 5
            ($all | Where-Object State -eq 'disabled').Method |
                Should -Be @('TemporaryAccessPass', 'X509Certificate')
        }
    }

    It 'classifies phishing resistance by Microsoft''s list, disabled methods included' {
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            $all = Get-MsecEntraAuthenticationMethod
            ($all | Where-Object IsPhishingResistant).Method |
                Should -Be @('Fido2', 'X509Certificate')
        }
    }

    It '-PhishableOnly returns enabled non-resistant methods and excludes disabled ones' {
        # A disabled weak method is not a way in, so it must not appear in the list of ways in.
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            (Get-MsecEntraAuthenticationMethod -PhishableOnly).Method |
                Should -Be @('MicrosoftAuthenticator', 'Sms')
        }
    }

    It '-EnabledOnly drops the disabled methods' {
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            (Get-MsecEntraAuthenticationMethod -EnabledOnly).Method |
                Should -Be @('Fido2', 'MicrosoftAuthenticator', 'Sms')
        }
    }

    It 'reports a group id when the name cannot be resolved, rather than a blank' {
        # A target that cannot be named is still a target. Blanking it would read as "no
        # restriction", which inverts the meaning.
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') {
                    return @{ authenticationMethodConfigurations = @(
                        @{ id = 'Sms'; state = 'enabled'
                           includeTargets = @(@{ id = 'deleted-group-id'; targetType = 'group' }) }) }
                }
                throw 'Request_ResourceNotFound'
            }
            $sms = Get-MsecEntraAuthenticationMethod
            $sms.IncludeTarget       | Should -Be @('deleted-group-id')
            $sms.AvailableToAllUsers | Should -BeFalse
        }
    }

    It 'resolves each distinct group once however many methods target it' {
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'Emergency-Access-Accounts' }
            }
            Get-MsecEntraAuthenticationMethod | Out-Null
            # g-break-glass is targeted twice - Fido2 includes it, MicrosoftAuthenticator
            # excludes it - and all_users costs no call at all, so the whole policy comes to
            # exactly one group lookup.
            Should -Invoke Invoke-MsecGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Path -like '*groups/g-break-glass*'
            }
        }
    }
    It 'names the missing permission when Graph refuses the policy' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraAuthenticationMethod } | Should -Throw '*Policy.Read.All*'
        }
    }

    It 'emits the documented type so the table view applies' {
        InModuleScope msec -Parameters @{ P = $policy } {
            param($P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*authenticationMethodsPolicy*') { return $P }
                return @{ displayName = 'x' }
            }
            (Get-MsecEntraAuthenticationMethod)[0].PSObject.TypeNames |
                Should -Contain 'MsecEntraAuthenticationMethod'
        }
    }
}
