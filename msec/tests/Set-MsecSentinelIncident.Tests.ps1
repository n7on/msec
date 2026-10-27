#Requires -Module Pester
#
# Tests for Set-MsecSentinelIncident.
#
# The traps:
#
#   THE API HAS NO PATCH. PUT REPLACES THE RESOURCE, so a body carrying only the changed
#   fields silently discards title, description, labels and owner. The command GETs first and
#   puts the existing properties back alongside the change.
#
#   THE ETAG IS CONCURRENCY CONTROL. Sent as If-Match so a concurrent edit fails the write
#   rather than being overwritten.
#
#   A CLASSIFICATION NEEDS A REASON, EXCEPT Undetermined WHICH MUST NOT HAVE ONE.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Set-MsecSentinelIncident' {

    BeforeEach {
        InModuleScope Msec {
            Mock Resolve-MsecSentinelWorkspace -MockWith {
                [pscustomobject]@{
                    Headers = @{ Authorization = 'Bearer t' }
                    Subscription = '00000000-0000-0000-0000-000000000000'
                    Workspaces = @([pscustomobject]@{ Name = 'contoso-sentinel'; ResourceGroupName = 'rg'
                                                      ResourceId = '/x'; Base = 'https://management.azure.com/x/providers/Microsoft.SecurityInsights' })
                }
            }
            Mock Get-MsecSentinelIncident -MockWith {
                [pscustomobject]@{ Number = 51; Name = 'guid-51'; Status = 'New' }
            }
        }
    }

    It 'refuses a classification with no reason, naming the rule' {
        InModuleScope Msec {
            { Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                  -Classification BenignPositive -Confirm:$false } |
                Should -Throw '*requires -ClassificationReason*'
        }
    }

    It 'refuses Undetermined WITH a reason, which the API rejects' {
        InModuleScope Msec {
            { Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                  -Classification Undetermined -ClassificationReason InaccurateData -Confirm:$false } |
                Should -Throw '*must NOT carry*'
        }
    }

    It 'refuses a classification unless the incident is being closed' {
        InModuleScope Msec {
            { Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel `
                  -Classification TruePositive -ClassificationReason SuspiciousActivity -Confirm:$false } |
                Should -Throw '*only to a closed incident*'
        }
    }

    It 'refuses a call that changes nothing' {
        InModuleScope Msec {
            { Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Confirm:$false } |
                Should -Throw '*Nothing to change*'
        }
    }

    It 'carries the existing properties into the PUT, because PUT replaces' {
        # THE BUG THIS PREVENTS. A body with only status would wipe title, description and
        # labels off the incident - data the caller never read and did not mean to touch.
        $body = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Put' } -MockWith {
                $script:SeenBody = $Body
                @{ properties = @{ status = 'Closed' } }
            }
            Mock Invoke-RestMethod -MockWith {
                @{ name = 'guid-51'; etag = 'etag-abc'
                   properties = @{ incidentNumber = 51; title = 'Original title'; description = 'Original description'
                                   status = 'New'; severity = 'High'; labels = @('keepme'); providerName = 'Azure Sentinel' } }
            }
            $null = Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                        -Classification BenignPositive -ClassificationReason SuspiciousButExpected -Confirm:$false
            $script:SeenBody
        }

        $body | Should -BeLike '*Original title*'
        $body | Should -BeLike '*Original description*'
        $body | Should -BeLike '*keepme*'
        $body | Should -BeLike '*Closed*'
    }

    It 'sends the etag as If-Match, so a concurrent edit is not overwritten' {
        $hdr = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Put' } -MockWith {
                $script:SeenHeaders = $Headers
                @{ properties = @{ status = 'Closed' } }
            }
            Mock Invoke-RestMethod -MockWith {
                @{ name = 'guid-51'; etag = 'etag-abc'
                   properties = @{ incidentNumber = 51; title = 't'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel' } }
            }
            $null = Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                        -Classification BenignPositive -ClassificationReason SuspiciousButExpected -Confirm:$false
            $script:SeenHeaders
        }

        $hdr['If-Match'] | Should -Be 'etag-abc'
    }

    It 'explains a 412 as a concurrent change rather than a permission problem' {
        $msg = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Put' } -MockWith {
                throw 'Response status code does not indicate success: 412 (PreconditionFailed).'
            }
            Mock Invoke-RestMethod -MockWith {
                @{ name = 'guid-51'; etag = 'etag-abc'
                   properties = @{ incidentNumber = 51; title = 't'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel' } }
            }
            try {
                Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                    -Classification BenignPositive -ClassificationReason SuspiciousButExpected -Confirm:$false | Out-Null
            } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*changed between the read and the write*'
        $msg | Should -BeLike '*nothing was written*'
    }

    It 'writes nothing under -WhatIf' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Put' } -MockWith { @{ properties = @{} } }
            Mock Invoke-RestMethod -MockWith {
                @{ name = 'guid-51'; etag = 'e'
                   properties = @{ incidentNumber = 51; title = 't'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel' } }
            }
            $null = Set-MsecSentinelIncident -Number 51 -WorkspaceName contoso-sentinel -Status Closed `
                        -Classification BenignPositive -ClassificationReason SuspiciousButExpected -WhatIf

            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'Put' }
        }
    }
}
