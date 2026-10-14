#Requires -Module Pester
#
# Tests for Get-MsecSentinelRule.
#
# The traps:
#
#   RULEID MUST COME FROM THE RESOURCE NAME, not the display name. The resource name is the
#   GUID that appears as alertPolicyId on every alert the rule raised, and it is the only
#   reliable join between a rule and its alerts. Display names are edited, duplicated between a
#   stock rule and a tuned copy, and localised.
#
#   A NAMED WORKSPACE THAT IS NOT FOUND MUST THROW, NOT RETURN NOTHING. Building the request
#   URL from an empty ResourceId produces '/providers/Microsoft.SecurityInsights/...' with no
#   scope, which Azure rejects as an AUTHORIZATION failure - sending the reader to check RBAC
#   for a workspace that was never located. That happened while writing this command.
#
#   GROUPING ABSENT IS NOT GROUPING DISABLED. A Fusion rule carries no incidentConfiguration at
#   all, so GroupingEnabled is $null; a Scheduled rule that has it switched off is $false.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop

    $script:StubbedAz = @()
    $azStubs = @{
        'Get-AzContext'                     = { [CmdletBinding()] param() }
        'Set-AzContext'                     = { [CmdletBinding()] param($SubscriptionId) }
        'Get-AzAccessToken'                 = { [CmdletBinding()] param($ResourceUrl) }
        'Get-AzOperationalInsightsWorkspace' = { [CmdletBinding()] param($ResourceGroupName, $Name) }
    }
    foreach ($c in $azStubs.Keys) {
        if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
            Set-Item "function:global:$c" -Value $azStubs[$c] -Force
            $script:StubbedAz += $c
        }
    }
}
AfterAll {
    foreach ($c in $script:StubbedAz) { Remove-Item "function:global:$c" -ErrorAction SilentlyContinue }
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecSentinelRule' {

    # Defined here, not in the Describe body: Pester runs the body during discovery, so a
    # function declared there does not exist when the It blocks actually run.
    BeforeAll {
        function Get-RuleRows {
            param([string] $Kql, [switch] $NoQuery)
            InModuleScope msec -Parameters @{ Kql = $Kql; NoQuery = [bool] $NoQuery } {
                # Assigned into module scope: a -Parameters variable is NOT in scope when the mock
                # body below actually runs, and reading it there yields $null on every row.
                $script:TestKql     = $Kql
                $script:TestNoQuery = $NoQuery

                Mock Get-AzOperationalInsightsWorkspace -MockWith {
                    @([pscustomobject]@{ Name='ws'; ResourceGroupName='rg'; ResourceId='/subscriptions/sub-1/x' })
                }
                Mock Invoke-RestMethod -MockWith {
                    if ("$Uri" -match 'onboardingStates') { [pscustomobject]@{ value = @(1) } }
                    else {
                        $props = if ($script:TestNoQuery) {
                            [pscustomobject]@{ displayName='Fusion rule'; enabled=$true; severity='High' }
                        }
                        else {
                            [pscustomobject]@{ displayName='Scheduled rule'; enabled=$true; severity='High'; query=$script:TestKql }
                        }
                        [pscustomobject]@{ value = @([pscustomobject]@{ name='r1'; kind='Scheduled'; properties=$props }) }
                    }
                }
                Get-MsecSentinelRule
            }
        }
    }

    BeforeEach {
        InModuleScope msec {
            Mock Get-AzContext     -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-1' } } }
            Mock Get-AzAccessToken -MockWith { [pscustomobject]@{ Token = 'tok' } }
            Mock Get-MsecEnvironment -MockWith { [pscustomobject]@{ ArmResource = 'https://management.azure.com' } }
        }
    }

    It 'takes RuleId from the resource name, which is the join key to the alerts' {
        $rows = InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @([pscustomobject]@{ Name = 'ws'; ResourceGroupName = 'rg'; ResourceId = '/subscriptions/sub-1/x' })
            }
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -match 'onboardingStates') { [pscustomobject]@{ value = @(1) } }
                else {
                    [pscustomobject]@{ value = @([pscustomobject]@{
                        name = '76f4905a-3204-422a-ab37-05a8ee27b303'
                        kind = 'Scheduled'
                        properties = [pscustomobject]@{
                            displayName = 'Azure DevOps Pull Request Policy Bypassing'
                            enabled = $true; severity = 'Medium'
                            alertRuleTemplateName = 'tpl-1'
                            incidentConfiguration = [pscustomobject]@{
                                createIncident = $true
                                groupingConfiguration = [pscustomobject]@{ enabled = $false; lookbackDuration = 'PT5H' }
                            }
                        } })
                    }
                }
            }
            Get-MsecSentinelRule
        }

        # The GUID, not the title - this is what alertPolicyId on an alert matches.
        $rows[0].RuleId | Should -Be '76f4905a-3204-422a-ab37-05a8ee27b303'
        $rows[0].DisplayName | Should -Be 'Azure DevOps Pull Request Policy Bypassing'
        $rows[0].GroupingEnabled | Should -BeFalse
        $rows[0].IsFromTemplate | Should -BeTrue
    }

    It 'reports GroupingEnabled as null when the rule carries no incident configuration' {
        $rows = InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @([pscustomobject]@{ Name = 'ws'; ResourceGroupName = 'rg'; ResourceId = '/subscriptions/sub-1/x' })
            }
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -match 'onboardingStates') { [pscustomobject]@{ value = @(1) } }
                else {
                    # A Fusion rule has no incidentConfiguration at all.
                    [pscustomobject]@{ value = @([pscustomobject]@{
                        name = 'fusion-1'; kind = 'Fusion'
                        properties = [pscustomobject]@{ displayName = 'Advanced Multistage Attack Detection'; enabled = $true; severity = 'High' } }) }
                }
            }
            Get-MsecSentinelRule
        }

        # $false would claim grouping was looked at and found switched off.
        $rows[0].GroupingEnabled | Should -BeNullOrEmpty
        $rows[0].Kind | Should -Be 'Fusion'
    }

    It 'throws, naming the workspace and subscription, when a named workspace is not found' {
        InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith { throw "Operation returned an invalid status code 'NotFound'" }
            # An empty result here would build a scope-less URL and surface as an authorization
            # failure, sending the reader to check RBAC on a workspace that does not exist.
            { Get-MsecSentinelRule -ResourceGroupName rg -WorkspaceName nope } |
                Should -Throw "*workspace 'nope'*subscription sub-1*"
        }
    }

    It 'throws when a named workspace exists but is not onboarded to Sentinel' {
        InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @([pscustomobject]@{ Name = 'plain'; ResourceGroupName = 'rg'; ResourceId = '/subscriptions/sub-1/x' })
            }
            Mock Invoke-RestMethod -MockWith { throw 'Not Found' }
            # Returning nothing would read as a Sentinel with no rules, which is alarming and
            # wrong - this workspace simply is not a Sentinel.
            { Get-MsecSentinelRule -ResourceGroupName rg -WorkspaceName plain } |
                Should -Throw '*not onboarded to Microsoft Sentinel*'
        }
    }

    It 'skips non-Sentinel workspaces silently when discovering' {
        $rows = InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @(
                    [pscustomobject]@{ Name = 'plain';    ResourceGroupName = 'rg'; ResourceId = '/subscriptions/sub-1/plain' }
                    [pscustomobject]@{ Name = 'sentinel'; ResourceGroupName = 'rg'; ResourceId = '/subscriptions/sub-1/sentinel' }
                )
            }
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -match 'onboardingStates') {
                    if ("$Uri" -match '/plain/') { throw 'Not Found' }
                    [pscustomobject]@{ value = @(1) }
                }
                else {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name='r1'; kind='Scheduled'
                        properties = [pscustomobject]@{ displayName='Rule'; enabled=$true; severity='Low' } }) }
                }
            }
            Get-MsecSentinelRule -WarningAction SilentlyContinue
        }

        # Most Log Analytics workspaces are not Sentinels; warning on each would be noise.
        @($rows).Count | Should -Be 1
        $rows[0].WorkspaceName | Should -Be 'sentinel'
    }

    It 'returns only enabled rules with -EnabledOnly' {
        $rows = InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @([pscustomobject]@{ Name='ws'; ResourceGroupName='rg'; ResourceId='/subscriptions/sub-1/x' })
            }
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -match 'onboardingStates') { [pscustomobject]@{ value = @(1) } }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name='r1'; kind='Scheduled'; properties=[pscustomobject]@{ displayName='On';  enabled=$true;  severity='Low' } }
                        [pscustomobject]@{ name='r2'; kind='Scheduled'; properties=[pscustomobject]@{ displayName='Off'; enabled=$false; severity='Low' } }
                    ) }
                }
            }
            Get-MsecSentinelRule -EnabledOnly
        }

        @($rows).Count | Should -Be 1
        $rows[0].DisplayName | Should -Be 'On'
    }

    It 'warns rather than silently omitting a workspace whose rules cannot be read' {
        InModuleScope msec {
            Mock Get-AzOperationalInsightsWorkspace -MockWith {
                @([pscustomobject]@{ Name='ws'; ResourceGroupName='rg'; ResourceId='/subscriptions/sub-1/x' })
            }
            Mock Invoke-RestMethod -MockWith {
                if ("$Uri" -match 'onboardingStates') { [pscustomobject]@{ value = @(1) } }
                else { throw 'Forbidden' }
            }
            Get-MsecSentinelRule -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $script:captured = $w
        }
        $captured = InModuleScope msec { $script:captured }

        "$captured" | Should -Match 'MISSING from this output'
    }
    # ---- Query and QueryTables -------------------------------------------------------------
    #
    # QueryTables is a scan, not a KQL parser, and both of the regressions below came from a
    # live workspace rather than from imagination. Every one of these is a shape that appeared
    # in a real Content Hub or hand-written rule.

    It 'carries the KQL itself and the table it reads' {
        $rows = Get-RuleRows -Kql "SigninLogs`n| where ResultType == 0`n| summarize count() by UserPrincipalName"

        $rows[0].Query       | Should -Match 'where ResultType'
        $rows[0].QueryTables | Should -Be @('SigninLogs')
    }

    It 'reports Query as null, not empty string, on a rule that has no query of its own' {
        # A Fusion or NRT rule's correlation is Microsoft's. An empty string would claim a
        # query exists and happens to be blank.
        $rows = Get-RuleRows -NoQuery

        $rows[0].Query       | Should -BeNullOrEmpty
        $rows[0].Query       | Should -Not -Be ''
        $null -eq $rows[0].Query | Should -BeTrue
        $rows[0].QueryTables | Should -BeNullOrEmpty
    }

    It 'excludes let-bound names, which read exactly like table references and are not' {
        $kql = @'
let Threshold = 3;
let Blocked = AGWFirewallLogs | where Action == "Blocked" | distinct TransactionId;
Blocked
| where TransactionId != ""
'@
        $rows = Get-RuleRows -Kql $kql

        # 'Blocked' begins a statement and is followed by a pipe - and is a local, not a table.
        $rows[0].QueryTables | Should -Be @('AGWFirewallLogs')
    }

    It 'follows union legs and join operands inside parentheses' {
        $kql = @'
union isfuzzy=true
  (AzureDiagnostics | where Category == "ApplicationGatewayFirewallLog" | project TimeGenerated),
  (AGWFirewallLogs | project TimeGenerated)
| join kind=inner (
    AuditLogs
    | where OperationName =~ "Add user"
) on TimeGenerated
'@
        $rows = Get-RuleRows -Kql $kql

        $rows[0].QueryTables | Should -Be @('AGWFirewallLogs', 'AuditLogs', 'AzureDiagnostics')
    }

    It 'does not report a union modifier fragment as a table' {
        # REGRESSION. Matching an identifier after a bare 'union' keyword let the regex
        # backtrack into 'isfuzzy=true' and report 'e' as the only table of three live WAF
        # rules - while the two tables they actually read went missing.
        $rows = Get-RuleRows -Kql 'union isfuzzy=true (AGWFirewallLogs | project TimeGenerated)'

        $rows[0].QueryTables | Should -Be @('AGWFirewallLogs')
        $rows[0].QueryTables | Should -Not -Contain 'e'
    }

    It 'does not report the trailing column of a summarize as a table' {
        # REGRESSION. 'Uri' here is followed by a pipe exactly as a table reference would be.
        # What rules it out is the character BEFORE it: a comma, not ';', '(', '{' or the
        # start of the query.
        $kql = @'
AGWAccessSummary_CL
| summarize Total = dcount(TransactionId) by clientIp_s = ClientIp, Uri
| where Total >= 3
'@
        $rows = Get-RuleRows -Kql $kql

        $rows[0].QueryTables | Should -Be @('AGWAccessSummary_CL')
        $rows[0].QueryTables | Should -Not -Contain 'Uri'
    }

    It 'finds a table inside a user-defined function body' {
        $kql = @'
let awsFunc = (start:datetime) {
  AuditLogs
  | where TimeGenerated > start
  | where Category =~ "RoleManagement"
};
awsFunc(ago(1h))
'@
        $rows = Get-RuleRows -Kql $kql

        $rows[0].QueryTables | Should -Be @('AuditLogs')
    }

    It 'ignores table names in comments and in string literals' {
        $kql = @'
// This rule used to read AzureDiagnostics before the migration.
SigninLogs
| where ResultDescription == "see SecurityEvent for detail"
'@
        $rows = Get-RuleRows -Kql $kql

        $rows[0].QueryTables | Should -Be @('SigninLogs')
    }

    It 'returns no tables when the rule names its table at run time' {
        # DOCUMENTED LIMIT, not a bug to fix: the name is built from a string at execution
        # time, so nothing in the text identifies it. The help says empty means 'none found'
        # rather than 'reads nothing', which is why this is asserted rather than left to chance.
        $kql = @'
let aadFunc = (tableName:string){
table(tableName)
| where ResultType == "50057"
};
let aadSignin = aadFunc("SigninLogs");
aadSignin
'@
        $rows = Get-RuleRows -Kql $kql

        $rows[0].QueryTables | Should -BeNullOrEmpty
        # The KQL is still there, so the dependency remains discoverable by reading it.
        $rows[0].Query | Should -Match 'SigninLogs'
    }
}
