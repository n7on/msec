#Requires -Module Pester
#
# Tests for Get-MsecDefenderIncident and Get-MsecDefenderAlert.
#
# Three things these commands must not get wrong, all of the same family - a value that means
# "no answer yet" must never render as a measurement:
#
#   ResolveDays on an open item is $null, never 0. Zero reads as "closed instantly", which is
#   the opposite of a still-running investigation.
#
#   A redirected incident was merged into another one. It is the same attack counted twice, so
#   it has to be visible and droppable - but never dropped silently, or a count that shrank has
#   no explanation.
#
#   serviceSource 'unknownFutureValue' is Graph saying it has no name for the source, not a
#   workload called that. It is passed through verbatim rather than guessed at.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecDefenderIncident' {
    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'leaves ResolveDays null while an incident is open' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'i1'; displayName = 'open'; severity = 'high'; status = 'active'
                                   classification = 'unknown'
                                   createdDateTime = '2026-09-01T00:00:00Z'; lastUpdateDateTime = '2026-09-10T00:00:00Z' }
                [pscustomobject]@{ id = 'i2'; displayName = 'done'; severity = 'low'; status = 'resolved'
                                   classification = 'unknown'
                                   createdDateTime = '2026-09-01T00:00:00Z'; lastUpdateDateTime = '2026-09-03T00:00:00Z' }
            }
            Get-MsecDefenderIncident -Days 90
        }

        ($rows | Where-Object Id -eq 'i1').ResolveDays | Should -BeNullOrEmpty
        ($rows | Where-Object Id -eq 'i2').ResolveDays | Should -Be 2
    }

    It 'returns redirected incidents by default and drops them only when asked' {
        $result = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'i1'; status = 'active';     severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z' }
                # Merged into i1 - the same attack, counted twice if this is treated as its own.
                [pscustomobject]@{ id = 'i2'; status = 'redirected'; severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z'
                                   redirectIncidentId = 'i1' }
            }
            [pscustomobject]@{
                All  = @(Get-MsecDefenderIncident -Days 90)
                Kept = @(Get-MsecDefenderIncident -Days 90 -ExcludeRedirected)
            }
        }
        $all  = @($result.All)
        $kept = @($result.Kept)

        $all.Count  | Should -Be 2
        $kept.Count | Should -Be 1
        # Visible rather than implied: the row names what absorbed it.
        ($all | Where-Object Id -eq 'i2').RedirectedToIncidentId | Should -Be 'i1'
    }

    It 'reports AlertCount as null when the alerts could not be read, not zero' {
        $row = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'incidents\?' } -MockWith {
                [pscustomobject]@{ id = 'i1'; status = 'active'; severity = 'low'; createdDateTime = '2026-09-01T00:00:00Z' }
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match '/alerts$' } -MockWith { throw 'Forbidden' }
            Get-MsecDefenderIncident -Days 90 -IncludeAlerts
        }

        # An incident whose alerts were refused has not been shown to have none.
        $row.AlertCount | Should -BeNullOrEmpty
    }

    It 'names the permission when the endpoint refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecDefenderIncident } | Should -Throw '*SecurityIncident.Read.All*'
        }
    }
}

Describe 'Get-MsecDefenderAlert' {
    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'passes unknownFutureValue through rather than guessing a workload' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                # 231 of 569 alerts on a live tenant came back exactly like this.
                [pscustomobject]@{ id = 'a1'; title = 'Role grant'; severity = 'high'; status = 'new'
                                   serviceSource = 'unknownFutureValue'; productName = 'Microsoft Entra ID'
                                   createdDateTime = '2026-09-01T00:00:00Z'; evidence = @(1, 2) }
            }
            Get-MsecDefenderAlert -Days 90
        }

        $rows.ServiceSource | Should -Be 'unknownFutureValue'
        # The fields that are often populated when ServiceSource is not.
        $rows.ProductName   | Should -Be 'Microsoft Entra ID'
        $rows.EvidenceCount | Should -Be 2
    }

    It 'leaves ResolveDays null while an alert is open' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                [pscustomobject]@{ id = 'a1'; status = 'new'; severity = 'low'
                                   createdDateTime = '2026-09-01T00:00:00Z' }
                [pscustomobject]@{ id = 'a2'; status = 'resolved'; severity = 'low'
                                   createdDateTime = '2026-09-01T00:00:00Z'; resolvedDateTime = '2026-09-04T00:00:00Z' }
            }
            Get-MsecDefenderAlert -Days 90
        }

        ($rows | Where-Object Id -eq 'a1').ResolveDays | Should -BeNullOrEmpty
        ($rows | Where-Object Id -eq 'a2').ResolveDays | Should -Be 3
    }

    It 'uses the alert status vocabulary, which is not the incident one' {
        # An alert is never 'active'; an incident never 'new'. Filtering both with one string
        # silently finds nothing in one of them, so the ValidateSet has to differ.
        $valid = (Get-Command Get-MsecDefenderAlert).Parameters['Status'].Attributes |
                     Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                     Select-Object -ExpandProperty ValidValues
        $valid | Should -Contain 'new'
        $valid | Should -Not -Contain 'active'
        $valid | Should -Not -Contain 'redirected'
    }
}

Describe 'Get-MsecDefenderAlert triage selection' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession {}
            $script:AlertQueryPath = $null
            $script:TestAlerts = @(
                @{ id = 'a1'; title = 'Old alert worked last week'; severity = 'low'; status = 'resolved'
                   classification = 'falsePositive'; determination = 'notMalicious'
                   assignedTo = 'analyst@contoso.com'; serviceSource = 'microsoftDefenderForEndpoint'
                   createdDateTime = '2025-01-01T00:00:00Z'
                   evidence = @(
                       @{ '@odata.type' = '#microsoft.graph.security.deviceEvidence'
                          deviceDnsName = 'VIE0001'; verdict = 'suspicious' }
                       @{ '@odata.type' = '#microsoft.graph.security.userEvidence'
                          userAccount = @{ userPrincipalName = 'alex@contoso.com' }; verdict = 'unknown' }
                   ) }
                @{ id = 'a2'; title = 'Suppressed'; severity = 'low'; status = 'resolved'
                   classification = 'falsePositive'; determination = 'notMalicious'
                   assignedTo = 'Suppression rule'; serviceSource = 'microsoftDefenderForEndpoint'
                   createdDateTime = '2026-01-01T00:00:00Z'; evidence = @() }
                @{ id = 'a3'; title = 'Untriaged'; severity = 'high'; status = 'new'
                   classification = 'unknown'; determination = 'unknown'
                   assignedTo = $null; serviceSource = 'microsoftDefenderForEndpoint'
                   createdDateTime = '2026-01-01T00:00:00Z'; evidence = @() }
            )
            Mock Invoke-MsecGraphRequest {
                $script:AlertQueryPath = $Path
                return $script:TestAlerts
            }
        }
    }

    It '-UpdatedWithin queries lastUpdateDateTime instead of createdDateTime' {
        # THE DEFECT THIS CLOSES. -Days finds alerts RAISED in a window, so an alert raised a
        # year ago and triaged last week is absent from it - which made a tenant holding 507
        # classified alerts read as having almost none.
        InModuleScope msec {
            Get-MsecDefenderAlert -UpdatedWithin 45 | Out-Null
            $script:AlertQueryPath | Should -Match 'lastUpdateDateTime ge'
            $script:AlertQueryPath | Should -Not -Match 'createdDateTime'
        }
    }

    It 'defaults to createdDateTime when -UpdatedWithin is not given' {
        InModuleScope msec {
            Get-MsecDefenderAlert -Days 7 | Out-Null
            $script:AlertQueryPath | Should -Match 'createdDateTime ge'
            $script:AlertQueryPath | Should -Not -Match 'lastUpdateDateTime'
        }
    }

    It '-UpdatedWithin REPLACES the created filter rather than ANDing with it' {
        # ANDing would ask for alerts raised AND touched in the window, dropping every old
        # alert worked recently - exactly the set -UpdatedWithin exists to find.
        InModuleScope msec {
            Get-MsecDefenderAlert -Days 7 -UpdatedWithin 45 | Out-Null
            $script:AlertQueryPath | Should -Not -Match 'createdDateTime'
        }
    }

    It '-TriagedBy selects a human analyst and excludes automation' {
        # 'Suppression rule' and 'MdcAlertsResourceProvider' appear in assignedTo on hundreds
        # of alerts. Treating those as verdicts means learning from a suppression rule.
        InModuleScope msec {
            (Get-MsecDefenderAlert -TriagedBy 'analyst@contoso.com').Id | Should -Be @('a1')
        }
    }

    It '-Classification and -Determination filter the labelled set' {
        InModuleScope msec {
            (Get-MsecDefenderAlert -Classification falsePositive).Id | Should -Be @('a1', 'a2')
            (Get-MsecDefenderAlert -Determination notMalicious).Id   | Should -Be @('a1', 'a2')
            # 'unknown' is what an untouched alert carries, so this is the UNtriaged set.
            (Get-MsecDefenderAlert -Classification unknown).Id       | Should -Be @('a3')
        }
    }

    It 'flattens polymorphic evidence to readable identifiers' {
        # Device, user, ip, file, mailbox and url evidence each carry different fields, so a
        # single property cannot be read off them - hence the per-kind resolution.
        InModuleScope msec {
            $ev = (Get-MsecDefenderAlert | Where-Object Id -eq 'a1').Evidence
            $ev | Should -Contain 'device: VIE0001 (suspicious)'
            # verdict 'unknown' adds nothing, so it is left off rather than printed.
            $ev | Should -Contain 'user: alex@contoso.com'
        }
    }

    It 'leaves EvidenceCount and Evidence consistent when there is none' {
        InModuleScope msec {
            $a3 = Get-MsecDefenderAlert | Where-Object Id -eq 'a3'
            $a3.EvidenceCount | Should -Be 0
            @($a3.Evidence).Count | Should -Be 0
        }
    }
}

Describe 'Get-MsecDefenderAlert -AnyAge' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession {}
            $script:AlertQueryPath = $null
            Mock Invoke-MsecGraphRequest {
                $script:AlertQueryPath = $Path
                return @(@{ id = 'a1'; title = 'T'; status = 'new'; severity = 'low'
                            classification = 'unknown'; createdDateTime = '2024-01-01T00:00:00Z'
                            evidence = @() })
            }
        }
    }

    It 'sends no date filter at all' {
        # -Days 365 is NOT equivalent: an alert older than the cap is invisible rather than
        # merely old, which is how an open backlog gets reported as empty.
        InModuleScope msec {
            Get-MsecDefenderAlert -AnyAge | Out-Null
            $script:AlertQueryPath | Should -Not -Match 'filter'
            $script:AlertQueryPath | Should -Not -Match 'createdDateTime'
            $script:AlertQueryPath | Should -Not -Match 'lastUpdateDateTime'
        }
    }

    It 'wins over both -Days and -UpdatedWithin rather than ANDing with them' {
        InModuleScope msec {
            Get-MsecDefenderAlert -AnyAge -Days 7 -UpdatedWithin 30 | Out-Null
            $script:AlertQueryPath | Should -Not -Match 'filter'
        }
    }

    It 'still applies the client-side filters' {
        InModuleScope msec {
            (Get-MsecDefenderAlert -AnyAge -Status new).Id      | Should -Be @('a1')
            (Get-MsecDefenderAlert -AnyAge -Status resolved).Id  | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-MsecDefenderIncident -AnyAge and attached alerts' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession {}
            $script:IncQueryPath = $null
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*/alerts*') {
                    return @(@{
                        id = 'al1'; title = 'Malicious blob'; severity = 'high'; status = 'new'
                        classification = 'unknown'; determination = 'unknown'
                        serviceSource = 'microsoftDefenderForCloud'
                        evidence = @(
                            @{ '@odata.type' = '#microsoft.graph.security.userEvidence'
                               userAccount = @{ userPrincipalName = 'alex@contoso.com' } }
                            @{ '@odata.type' = '#microsoft.graph.security.ipEvidence'
                               ipAddress = '203.0.113.9' }
                        )
                    })
                }
                $script:IncQueryPath = $Path
                return @(@{ id = 'i1'; displayName = 'Blob incident'; severity = 'high'
                            status = 'active'; createdDateTime = '2024-01-01T00:00:00Z' })
            }
        }
    }

    It '-AnyAge sends no date filter' {
        InModuleScope msec {
            Get-MsecDefenderIncident -AnyAge | Out-Null
            $script:IncQueryPath | Should -Not -Match 'filter'
        }
    }

    It '-IncludeAlerts attaches the alerts themselves, not just a count' {
        # Without this every caller re-fetches alerts_v2 and joins on IncidentId by hand.
        InModuleScope msec {
            $i = Get-MsecDefenderIncident -AnyAge -IncludeAlerts
            $i.AlertCount        | Should -Be 1
            @($i.Alerts).Count   | Should -Be 1
            $i.Alerts[0].Title   | Should -Be 'Malicious blob'
            $i.Alerts[0].Status  | Should -Be 'new'
        }
    }

    It 'flattens the attached alerts evidence the same way the alert command does' {
        InModuleScope msec {
            $ev = (Get-MsecDefenderIncident -AnyAge -IncludeAlerts).Alerts[0].Evidence
            $ev | Should -Contain 'user: alex@contoso.com'
            $ev | Should -Contain 'ip: 203.0.113.9'
        }
    }

    It 'leaves Alerts empty rather than null when -IncludeAlerts is not used' {
        # Empty and null are different things to a caller; an empty array is safe to iterate.
        InModuleScope msec {
            $i = Get-MsecDefenderIncident -AnyAge
            @($i.Alerts).Count | Should -Be 0
            $i.AlertCount      | Should -BeNullOrEmpty
        }
    }
}
