function Get-MsecSentinelRule {
    <#
    .SYNOPSIS
        Microsoft Sentinel analytics rules with their tuning state - severity, alert grouping,
        suppression - and the id that joins them to the alerts they produced.

    .DESCRIPTION
        A Sentinel workspace accumulates rules from the Content Hub faster than anyone tunes
        them, and the portal shows one rule at a time. This returns all of them as flat rows,
        so 'which rules have never been tuned' and 'which rules produce every alert we close as
        a false positive' are both one pipeline.

        RULEID IS THE JOIN TO THE ALERTS. A rule's resource name is a GUID, and that GUID is
        the alertPolicyId on every alert the rule raised - so RuleId joins directly to
        Get-MsecDefenderAlert's Raw.alertPolicyId. Matching on the display name instead looks
        equivalent and is not: titles are edited, duplicated between a stock rule and a tuned
        copy, and localised.

        TUNING STATE IS THE POINT, NOT THE QUERY. GroupingEnabled, SuppressionEnabled and
        TriggerThreshold are what decide how much noise a rule makes. Alert grouping in
        particular is off by default on every Content Hub rule, and with it off each alert
        becomes its own incident - measured on one workspace, 0 of 48 rules had it enabled.

        QUERYTABLES IS A SCAN OF THE KQL, NOT A PARSE, AND EMPTY MEANS 'NONE FOUND'. It answers
        the question a rule list cannot otherwise answer - which rules read a table that holds
        no data, because such a rule is enabled, green, and can never fire. Comments, string
        literals and let-bound names are excluded; union legs, join operands and function
        bodies are followed. Measured against a live workspace it resolved 19 of 20 scheduled
        rules correctly. The twentieth builds its table name at run time - 'table(tableName)'
        fed from a string - which no scan of the text can see, so it comes back empty. Treat an
        empty list as 'nothing found', never as 'reads nothing'; Query has the KQL itself.

        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP. Sentinel is an Azure resource, so this
        reads through ARM on your Az context like Get-MsecAzureSecureScore and
        Search-MsecAzureResourceGraph. The app certificate holds Graph permissions, not Azure
        RBAC. One command, one identity.

        A WORKSPACE THAT IS NOT ONBOARDED TO SENTINEL IS SKIPPED WHEN DISCOVERING, AND NAMED
        WHEN ASKED FOR. Discovery walks the Log Analytics workspaces in scope and most of them
        are ordinary log workspaces; naming one explicitly and getting silence back would read
        as a Sentinel with no rules, which is a different and much more alarming thing.

    .PARAMETER SubscriptionId
        Subscription to search. Defaults to the active Az context. Use Select-MsecAzureContext
        to move the context itself.

    .PARAMETER ResourceGroupName
        Only workspaces in this resource group.

    .PARAMETER WorkspaceName
        A specific Log Analytics workspace. Omit to find every Sentinel-onboarded workspace in
        scope.

    .PARAMETER EnabledOnly
        Only rules that are switched on.

    .EXAMPLE
        Get-MsecSentinelRule | Where-Object { $_.Enabled -and -not $_.GroupingEnabled }

        Enabled rules with alert grouping off - every alert becomes its own incident.

    .EXAMPLE
        $rules  = Get-MsecSentinelRule
        $alerts = Get-MsecDefenderAlert
        $alerts | Group-Object { $_.Raw.alertPolicyId } | ForEach-Object {
            $rule = $rules | Where-Object RuleId -eq $_.Name
            [pscustomobject]@{
                Rule       = if ($rule) { $rule.DisplayName } else { '(not a Sentinel rule)' }
                Alerts     = $_.Count
                Grouping   = $rule.GroupingEnabled
                Severity   = $rule.Severity
            }
        } | Sort-Object Alerts -Descending

        Alert volume per rule, with whether that rule has ever been tuned. This is the join the
        command exists for.

    .EXAMPLE
        Get-MsecSentinelRule -EnabledOnly |
            Where-Object { $_.QueryTables -contains 'SigninLogs' }

        Which enabled rules depend on a given table. If that table is empty in this workspace,
        every rule listed here is switched on and cannot fire.

    .EXAMPLE
        Get-MsecSentinelRule -EnabledOnly |
            Group-Object Severity | Sort-Object Count -Descending

        How many rules sit at each severity. A tier with most of the rules in it is a volume
        band, not a severity.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $SubscriptionId,

        [string] $ResourceGroupName,

        [string] $WorkspaceName,

        [switch] $EnabledOnly
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-AzAccount first - this command runs as you, not as the msec app.'
    }

    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-Verbose "Switching context to subscription $SubscriptionId"
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }
    $subscription = $context.Subscription.Id

    $arm = (Get-MsecEnvironment).ArmResource
    $tokenResponse = Get-AzAccessToken -ResourceUrl "$arm/" -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }
    $headers = @{ Authorization = "Bearer $token" }

    $workspaceParams = @{ ErrorAction = 'Stop' }
    if ($ResourceGroupName) { $workspaceParams['ResourceGroupName'] = $ResourceGroupName }
    if ($WorkspaceName -and $ResourceGroupName) { $workspaceParams['Name'] = $WorkspaceName }

    # Get-AzOperationalInsightsWorkspace throws its own bare "Operation returned an invalid
    # status code 'NotFound'" for a name that does not exist, which says nothing about WHICH
    # name or WHICH subscription was searched. Caught here so the message below is the one the
    # reader sees.
    $workspaces = @()
    try {
        $workspaces = @(Get-AzOperationalInsightsWorkspace @workspaceParams)
    }
    catch {
        if ("$($_.Exception.Message)" -notmatch 'NotFound|ResourceNotFound') { throw }
        Write-Verbose "Workspace lookup returned NotFound: $($_.Exception.Message)"
    }
    if ($WorkspaceName) { $workspaces = @($workspaces | Where-Object { $_.Name -eq $WorkspaceName }) }

    # Named and not found is an error, never an empty result. Building the request URL from an
    # empty ResourceId yields '/providers/Microsoft.SecurityInsights/...' with no scope at all,
    # which Azure rejects with an authorization failure - sending the reader to check RBAC for
    # a workspace that was never located. This happened while writing the command.
    if (-not $workspaces.Count) {
        $where = @(
            if ($WorkspaceName)     { "workspace '$WorkspaceName'" }
            if ($ResourceGroupName) { "resource group '$ResourceGroupName'" }
        ) -join ' in '
        if ($where) {
            throw "No Log Analytics $where found in subscription $subscription. Check the name, and that the active context is the right subscription - Get-AzContext shows which."
        }
        Write-Warning "No Log Analytics workspaces found in subscription $subscription, so no Sentinel rules could be read. This is not the same as a Sentinel with no rules."
        return
    }

    $onboarded = 0
    foreach ($workspace in $workspaces) {
        $base = "$arm$($workspace.ResourceId)/providers/Microsoft.SecurityInsights"

        # Onboarding is what separates a Sentinel from an ordinary log workspace. Probed per
        # workspace because there is no way to filter for it when listing.
        $isSentinel = $false
        try {
            $null = Invoke-RestMethod -Headers $headers -ErrorAction Stop `
                -Uri "$base/onboardingStates?api-version=2024-09-01"
            $isSentinel = $true
        }
        catch {
            if ($WorkspaceName) {
                throw "Workspace '$($workspace.Name)' exists but is not onboarded to Microsoft Sentinel, so it has no analytics rules. $($_.Exception.Message)"
            }
            Write-Verbose "Skipping '$($workspace.Name)': not onboarded to Sentinel."
            continue
        }
        if (-not $isSentinel) { continue }
        $onboarded++

        $rules = $null
        try {
            $rules = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop `
                -Uri "$base/alertRules?api-version=2024-09-01").value)
        }
        catch {
            Write-Warning "Could not read analytics rules from '$($workspace.Name)', so it is MISSING from this output rather than reported as having none: $($_.Exception.Message)"
            continue
        }

        foreach ($rule in $rules) {
            $p = $rule.properties
            if ($EnabledOnly -and -not $p.enabled) { continue }

            $grouping = $p.incidentConfiguration.groupingConfiguration

            # THE TABLES THE RULE READS, found by scanning the KQL. Comments and string
            # literals are stripped first, so a table named in prose or inside a quoted
            # string is not counted as a dependency.
            $kql = [string] $p.query
            $stripped = ($kql -replace '(?m)//.*$', '') -replace '"[^"]*"', '""' -replace "'[^']*'", "''"

            # let-bound names are local, not tables: 'let Blocked = ... ; Blocked | where'
            # reads exactly like a table reference and is not one.
            $letNames = @([regex]::Matches($stripped, '(?m)\blet\s+([A-Za-z_][A-Za-z0-9_]*)\s*=') |
                          ForEach-Object { $_.Groups[1].Value })

            # A table reference is an identifier followed by a pipe AND preceded by the start
            # of the query, ';', '(' or '{' - the four places a KQL statement can begin: top
            # level, a union leg or join operand, and a user-defined function body.
            #
            # THE PRECEDING CHARACTER IS WHAT MAKES THIS WORK. Matching "identifier followed by
            # a pipe" alone also matches the last column of a summarize - 'by clientIp_s =
            # ClientIp, Uri | where ...' yields 'Uri' - and matching after a bare union/join
            # keyword instead picks up its own modifiers: against a live workspace that
            # returned 'e', the tail of 'isfuzzy=true' after the regex backtracked into it.
            $tableMatches = @([regex]::Matches($stripped, '(?s)(?:\A|[;({])\s*([A-Za-z_][A-Za-z0-9_]*)\s*\|') |
                              ForEach-Object { $_.Groups[1].Value })

            # 'let Blocked = AGWFirewallLogs | where ...' puts the table after an '=' sign.
            # Matched only in the let form: adding '=' to the class above would also take the
            # right-hand side of '| extend Foo = Bar | ...', which is a column.
            $tableMatches += @([regex]::Matches($stripped, '(?s)\blet\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\|') |
                               ForEach-Object { $_.Groups[1].Value })

            # Bare union operands - 'union A, B' with no parentheses - have no pipe of their
            # own. key=value modifiers are removed first rather than matched around, which is
            # the backtracking trap described above.
            foreach ($u in [regex]::Matches($stripped, '(?is)\bunion\b([^;|]*)')) {
                foreach ($operand in (($u.Groups[1].Value -replace '\w+\s*=\s*\w+', '') -split ',')) {
                    $operand = $operand.Trim()
                    if ($operand -match '^[A-Za-z_][A-Za-z0-9_]*$') { $tableMatches += $operand }
                }
            }

            $tables = @($tableMatches |
                        Where-Object { $_ -and $_ -notin $letNames -and
                                       $_ -notmatch '^(let|union|join|print|range|datatable|externaldata|find|search)$' } |
                        Sort-Object -Unique)

            [PSCustomObject]@{
                PSTypeName             = 'MsecSentinelRule'
                SubscriptionId         = $subscription
                ResourceGroupName      = $workspace.ResourceGroupName
                WorkspaceName          = $workspace.Name
                # The join key to Get-MsecDefenderAlert's Raw.alertPolicyId.
                RuleId                 = [string] $rule.name
                DisplayName            = [string] $p.displayName
                Kind                   = [string] $rule.kind
                Enabled                = [bool] $p.enabled
                Severity               = [string] $p.severity
                Tactics                = @($p.tactics)
                Techniques             = @($p.techniques)
                # THE KQL ITSELF, and the tables it reads. Without these the only way to
                # answer "which table does this rule depend on" was to reach into
                # Raw.properties.query by hand - which is how a rule pointed at an empty
                # table stays invisible: it is enabled, it is green, and it can never fire.
                #
                # NULL ON A FUSION OR NRT RULE, not empty string. Those have no query of
                # their own - the correlation is Microsoft's - so an empty string would
                # claim a query exists and is blank.
                Query                  = if ($p.PSObject.Properties.Name -contains 'query') { [string] $p.query } else { $null }
                # Best-effort, and empty means 'none found' rather than 'reads nothing' -
                # a rule naming its table at run time has none to find. See the help.
                QueryTables            = @($tables)

                # Scheduled rules only; a Fusion or NRT rule has no schedule of its own, so
                # these are null rather than being invented.
                QueryFrequency         = [string] $p.queryFrequency
                QueryPeriod            = [string] $p.queryPeriod
                TriggerOperator        = [string] $p.triggerOperator
                TriggerThreshold       = $p.triggerThreshold
                CreateIncident         = $p.incidentConfiguration.createIncident
                # The two tuning levers. Both default OFF on Content Hub rules.
                GroupingEnabled        = if ($null -eq $grouping) { $null } else { [bool] $grouping.enabled }
                GroupingLookback       = [string] $grouping.lookbackDuration
                GroupingMatchingMethod = [string] $grouping.matchingMethod
                SuppressionEnabled     = $p.suppressionEnabled
                SuppressionDuration    = [string] $p.suppressionDuration
                # A rule still carrying a template id and never modified since install is stock.
                TemplateId             = [string] $p.alertRuleTemplateName
                IsFromTemplate         = [bool] $p.alertRuleTemplateName
                LastModifiedUtc        = $p.lastModifiedUtc
                Raw                    = $rule
            }
        }
    }

    if (-not $WorkspaceName -and $onboarded -eq 0) {
        Write-Warning "None of the $($workspaces.Count) Log Analytics workspace(s) in subscription $subscription are onboarded to Microsoft Sentinel."
    }
}
