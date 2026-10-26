#Requires -Module Pester
#
# Tests for Get-MsecDefenderIndicator. It LISTS the Defender indicator API on a DELEGATED
# token from the Az context, because that API has no read-only scope and the msec app is
# deliberately read-only.
#
# The traps:
#
#   THIS API HAS NO Ti.Read. Listing needs Ti.ReadWrite, a write scope, so a 403 here is an
#   authorization failure on the USER and the error must say so - sending someone to check
#   the app registration wastes the afternoon.
#
#   NO EXPIRY IS THE NORMAL CASE. Measured on one tenant, 63 of 63 indicators had no
#   expirationTime. $null means permanent; a far-future date would be a different fact.
#
#   EMPTY SCOPE MEANS TENANT-WIDE. rbacGroupNames comes back empty when an indicator applies
#   everywhere, which reads like missing data and is the opposite.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecDefenderIndicator' {
    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'me@contoso.com' } } }
            Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'delegated-token' } }
            Mock Get-MsecEnvironment -MockWith {
                @{ DefenderResource = 'https://api.securitycenter.microsoft.com'; EnvironmentName = 'AzureCloud' }
            }
        }
    }

    It 'names the USER scope on a 403, not the app registration' {
        # THE BUG THIS PREVENTS. The msec app is read-only by design and will never hold
        # Ti.ReadWrite, so "check the app permissions" is always the wrong advice here.
        $msg = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { Get-MsecDefenderIndicator | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*Ti.ReadWrite*'
        $msg | Should -BeLike '*me@contoso.com*'
        $msg | Should -BeLike '*not on the msec app*'
    }

    It 'reports no expiry as $null rather than inventing a date' {
        $r = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(
                    [pscustomobject]@{ id='1'; indicatorValue='evil.example'; indicatorType='DomainName'
                                       action='Block'; expirationTime=$null; rbacGroupNames=@() },
                    [pscustomobject]@{ id='2'; indicatorValue='other.example'; indicatorType='DomainName'
                                       action='Block'; expirationTime='2027-01-01T00:00:00Z'; rbacGroupNames=@() }
                ) }
            }
            Get-MsecDefenderIndicator
        }

        ($r | Where-Object Id -eq '1').ExpiresUtc | Should -BeNullOrEmpty
        ($r | Where-Object Id -eq '2').ExpiresUtc | Should -BeOfType [datetime]
    }

    It 'calls an empty scope tenant-wide, because blank reads as missing data' {
        $r = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(
                    [pscustomobject]@{ id='1'; indicatorValue='a'; indicatorType='Url'; action='Audit'
                                       rbacGroupNames=@() },
                    [pscustomobject]@{ id='2'; indicatorValue='b'; indicatorType='Url'; action='Audit'
                                       rbacGroupNames=@('Servers','Laptops') }
                ) }
            }
            Get-MsecDefenderIndicator
        }

        ($r | Where-Object Id -eq '1').Scope | Should -Be 'Tenant-wide'
        ($r | Where-Object Id -eq '2').Scope | Should -Be 'Servers; Laptops'
    }

    It 'follows @odata.nextLink, so a long inventory is not silently truncated' {
        # A security inventory that stops at one page is worse than a slow one: the missing
        # entries look like indicators that were never created.
        $r = InModuleScope Msec {
            $script:Calls = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Calls++
                if ($script:Calls -eq 1) {
                    @{ value = @([pscustomobject]@{ id='1'; indicatorValue='a'; indicatorType='Url'; action='Block'; rbacGroupNames=@() })
                       '@odata.nextLink' = 'https://api.securitycenter.microsoft.com/api/indicators?page=2' }
                }
                else {
                    @{ value = @([pscustomobject]@{ id='2'; indicatorValue='b'; indicatorType='Url'; action='Block'; rbacGroupNames=@() }) }
                }
            }
            Get-MsecDefenderIndicator
        }

        @($r).Count | Should -Be 2
        @($r).Id    | Should -Contain '2'
    }

    It 'warns rather than throwing for a type this tenant does not have' {
        # Microsoft adds indicator types without warning, so an unmatched filter is an empty
        # result and a note, not an invalid argument.
        $w = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @([pscustomobject]@{ id='1'; indicatorValue='a'; indicatorType='Url'; action='Block'; rbacGroupNames=@() }) }
            }
            $r = Get-MsecDefenderIndicator -Type 'FileSha256' -WarningVariable wv -WarningAction SilentlyContinue
            [pscustomobject]@{ Count = @($r).Count; Warning = ($wv -join ' ') }
        }

        $w.Count   | Should -Be 0
        $w.Warning | Should -BeLike '*FileSha256*'
        $w.Warning | Should -BeLike '*Url*'
    }

    It 'refuses a sovereign cloud instead of returning an empty list' {
        # Defender for Endpoint is commercial-only. An empty result there would read as
        # "no indicators configured", which is a different and wrong answer.
        $msg = InModuleScope Msec {
            Mock Get-MsecEnvironment -MockWith { @{ DefenderResource = $null; EnvironmentName = 'AzureChinaCloud' } }
            try { Get-MsecDefenderIndicator | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*AzureChinaCloud*'
        $msg | Should -BeLike '*commercial-only*'
    }

    It 'names Connect-MsecAzure when there is no Az context' {
        $msg = InModuleScope Msec {
            Mock Get-AzContext -MockWith { $null }
            try { Get-MsecDefenderIndicator | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*Connect-MsecAzure*'
        $msg | Should -BeLike '*not as the msec app*'
    }
}
