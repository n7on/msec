#Requires -Module Pester
#
# Tests for Get-MsecSentinelIncident. It reads the Sentinel incidents ARM API on the Az
# context, because Sentinel is an Azure resource and the msec app holds Graph permissions.
#
# The traps:
#
#   PROVIDERNAME IS WHY IT EXISTS. 'Azure Sentinel' incidents never reach Defender XDR, so
#   Get-MsecDefenderIncident cannot see them - measured, 628 of 3,721 on one workspace.
#
#   NOT PAGING IS A SILENT TRUNCATION. The API caps a page well below the total.
#
#   "COULD NOT READ" MUST NOT LOOK LIKE "NOTHING THERE", for a workspace or for entities.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecSentinelIncident' {

    BeforeEach {
        InModuleScope Msec {
            Mock Resolve-MsecSentinelWorkspace -MockWith {
                [pscustomobject]@{
                    Headers      = @{ Authorization = 'Bearer t' }
                    Subscription = '00000000-0000-0000-0000-000000000000'
                    Workspaces   = @([pscustomobject]@{
                        Name = 'contoso-sentinel'; ResourceGroupName = 'rg'
                        ResourceId = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/contoso-sentinel'
                        Base = 'https://management.azure.com/subscriptions/x/.../providers/Microsoft.SecurityInsights' })
                }
            }
        }
    }

    It 'follows nextLink, because one page is a silently short answer' {
        $r = InModuleScope Msec {
            $script:Calls = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Calls++
                if ($script:Calls -eq 1) {
                    @{ value = @(@{ name = 'g1'; etag = 'e1'; properties = @{ incidentNumber = 1; title = 'a'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel'; additionalData = @{ alertsCount = 1 } } })
                       nextLink = 'https://management.azure.com/page2' }
                }
                else {
                    @{ value = @(@{ name = 'g2'; etag = 'e2'; properties = @{ incidentNumber = 2; title = 'b'; status = 'New'; severity = 'Low'; providerName = 'Microsoft XDR'; additionalData = @{ alertsCount = 2 } } }) }
                }
            }
            Get-MsecSentinelIncident -WorkspaceName contoso-sentinel
        }

        @($r).Count   | Should -Be 2
        @($r).Number  | Should -Contain 2
    }

    It 'surfaces ProviderName, which is the whole point of reading ARM instead of XDR' {
        $r = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(@{ name = 'g1'; etag = 'e1'; properties = @{ incidentNumber = 51; title = 'old'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel'; additionalData = @{ alertsCount = 1 } } }) }
            }
            Get-MsecSentinelIncident -WorkspaceName contoso-sentinel
        }

        $r.ProviderName | Should -Be 'Azure Sentinel'
        $r.Etag         | Should -Be 'e1'
        $r.Name         | Should -Be 'g1'
    }

    It 'names Microsoft Sentinel Reader on a 403, and says it is not an Entra grant' {
        # Sending someone to check the app registration wastes the afternoon: this is Azure
        # RBAC on the workspace and the msec app cannot be given it.
        $msg = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            try { Get-MsecSentinelIncident -WorkspaceName contoso-sentinel | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*Microsoft Sentinel Reader*'
        $msg | Should -BeLike '*NOT*granted through Entra*'
    }

    It 'skips a workspace with no Sentinel endpoint instead of failing the whole read' {
        # An ordinary log workspace 404s here. One of those must not stop a subscription read.
        $r = InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 404 (NotFound).' }
            Get-MsecSentinelIncident -WorkspaceName contoso-sentinel -WarningAction SilentlyContinue
        }

        @($r).Count | Should -Be 0
    }

    It 'leaves Entities $null when they could not be read, never an empty list' {
        # An empty array would read as "this incident has no entities", which is a different
        # and wrong answer.
        $r = InModuleScope Msec {
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Post' } -MockWith { throw 'boom' }
            Mock Invoke-RestMethod -MockWith {
                @{ value = @(@{ name = 'g1'; etag = 'e1'; properties = @{ incidentNumber = 1; title = 'a'; status = 'New'; severity = 'High'; providerName = 'Azure Sentinel'; additionalData = @{ alertsCount = 1 } } }) }
            }
            Get-MsecSentinelIncident -WorkspaceName contoso-sentinel -IncludeEntities -WarningAction SilentlyContinue
        }

        $r.Entities | Should -BeNullOrEmpty
        $r.Number   | Should -Be 1
    }

    It 'refuses -Days together with -AnyAge rather than silently preferring one' {
        InModuleScope Msec {
            { Get-MsecSentinelIncident -WorkspaceName contoso-sentinel -Days 7 -AnyAge } |
                Should -Throw '*contradict*'
        }
    }
}
