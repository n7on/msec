function Get-MsecMySqlConfiguration {
    <#
    .SYNOPSIS
        One row per MySQL flexible server per server parameter - the value, the default, and
        whether a person set it or the platform did.

    .DESCRIPTION
        RESOURCE GRAPH CANNOT SEE SERVER PARAMETERS AT ALL, which is the whole reason this
        command exists. flexibleServers/configurations, /firewallRules and /databases each
        return ZERO rows from the Resources table - re-verified against 12 live servers - and
        the parent server row carries no parameter data either. So the posture questions that
        matter most about a database engine, "is TLS required" and "which protocol versions are
        accepted", are invisible to Search-MsecAzureResourceGraph and to every .kql in
        kql/Graph. They need a per-server ARM call, and that is what this does.

        SOURCE SAYS WHETHER SOMEONE CHANGED IT. COMPARING VALUE TO DEFAULTVALUE DOES NOT, AND
        IS WRONG IN BOTH DIRECTIONS. Azure reports 'user-override' or 'system-default' per
        parameter, and that is the authoritative signal. Measured on one production server:
        require_secure_transport has Value 'ON' and DefaultValue 'ON' - identical - and Source
        'user-override', because somebody set it explicitly. A report built on Value -ne
        DefaultValue would not list it, and would therefore miss the server where the same
        parameter was deliberately turned OFF for the same reason. 21 of 438 parameters on that
        server were user-overrides. Measured across one estate: 5,230 parameters over 12
        servers, of which 147 were user-overrides - under 3%. That short list is the one worth
        reading, and it is how two production servers were found accepting unencrypted
        connections. Use -UserOverride, or filter on IsUserOverride.

        ISREADONLY ARRIVES AS THE STRING 'False', AND [bool] 'False' IS $true IN POWERSHELL.
        Every boolean on this endpoint is a string, so casting instead of comparing turns every
        read-only parameter into a settable one and vice versa - silently, with no error
        anywhere. They are parsed by string comparison here and surfaced as real booleans, so
        callers never have to know. 162 of 438 parameters are read-only on a current server:
        binlog_encryption and innodb_redo_log_encrypt among them, which is why "we could just
        turn on binlog encryption" is not an option on this platform.

        VALUE IS WHAT WILL APPLY; CURRENTVALUE IS WHAT IS RUNNING. They differ when a change is
        waiting for a restart, and PendingRestart says so. Reporting Value alone would claim a
        setting is in force when the engine has not picked it up yet - for a control like
        require_secure_transport that is the difference between protected and not.

        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP. These are Azure resources, so this
        reads through ARM on your Az context like Get-MsecSentinelRule. The app certificate
        holds Graph permissions, not Azure RBAC.

        ONE ARM CALL PER SERVER, each returning every parameter - 438 on MySQL 8.4, 392 on 5.7,
        5,230 rows across a 12-server estate.
        -Name filters client-side because the API has no parameter-name filter, so narrowing by
        name saves nothing; narrowing by -ServerName does.

    .PARAMETER ServerName
        Only servers whose name matches this wildcard pattern, e.g. 'contoso-*'.

    .PARAMETER Name
        Only parameters matching these wildcard patterns, e.g. 'tls_*', '*encrypt*'. Filtered
        client-side - every parameter is fetched regardless.

        AN UNMATCHED NAME RETURNS NOTHING RATHER THAN FAILING, and a pattern that matched
        nothing is WARNED about by name, because an empty result from a typo looks exactly
        like an empty result from a clean estate. Server PROPERTIES are not parameters: the
        engine version, location and state come from
        Search-MsecAzureResourceGraph -ResourceType MySQL, not from here. A work item shipped
        with '-Name version' as its reproduce command on that misunderstanding; it returns no
        rows, and silence reads as "no problem found".

    .PARAMETER UserOverride
        Only parameters someone has set explicitly - Source 'user-override'. This is the
        deviation report, and it is NOT the same as Value -ne DefaultValue; see the
        description.

    .PARAMETER SubscriptionId
        Limit discovery to these subscriptions. Defaults to every subscription in reach.

    .EXAMPLE
        Get-MsecMySqlConfiguration -UserOverride |
            Format-Table ServerName, Parameter, Value, DefaultValue

        Everything a person has deliberately changed, across the estate. The short list worth
        reading - 21 of 438 parameters on a typical server.

    .EXAMPLE
        # The control that matters, and the servers that do not have it.
        Get-MsecMySqlConfiguration -Name require_secure_transport |
            Where-Object Value -ne 'ON'

    .EXAMPLE
        Get-MsecMySqlConfiguration -Name 'tls_version','*encrypt*' |
            Format-Table ServerName, Parameter, Value, IsReadOnly

        Transport and at-rest settings together. IsReadOnly tells you which of them you could
        actually change.

    .OUTPUTS
        One PSCustomObject per server per parameter, PSTypeName 'MsecMySqlConfiguration'.

    .NOTES
        Read-only. Needs Reader on the servers through your Az context - not a Graph permission.
        A server whose parameters cannot be read is WARNED about and omitted, never reported as
        having none.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $ServerName,

        [string[]] $Name,

        [switch] $UserOverride,

        [string[]] $SubscriptionId
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-AzAccount first - this command runs as you, not as the msec app.'
    }

    $discover = @{ ResourceType = 'MySQL'; Name = 'All' }
    if ($SubscriptionId) { $discover['Subscription'] = $SubscriptionId }
    $servers = @(Search-MsecAzureResourceGraph @discover)
    if ($ServerName) { $servers = @($servers | Where-Object { $_.Name -like $ServerName }) }

    if (-not $servers.Count) {
        Write-Warning "No MySQL flexible servers found$(if ($ServerName) { " matching '$ServerName'" }). This is not the same as servers with no parameters."
        return
    }

    $arm = (Get-MsecEnvironment).ArmResource
    $tokenResponse = Get-AzAccessToken -ResourceUrl "$arm/" -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }
    $headers = @{ Authorization = "Bearer $token" }

    $unreadable = 0
    $i = 0
    # Which -Name patterns actually matched something. A wildcard that matches nothing returns
    # an empty set with no error, which reads as "no deviation found" rather than "that is not
    # a parameter" - the same "could not find" rendering as "nothing there" this module warns
    # about everywhere else. Tracked so it can be said out loud at the end.
    $matchedPattern = @{}
    foreach ($pattern in @($Name)) { if ($pattern) { $matchedPattern[$pattern] = $false } }
    foreach ($server in $servers) {
        $i++
        Write-Progress -Id 1840 -Activity 'Reading MySQL server parameters' `
            -Status "$i of $($servers.Count) - $($server.Name)" `
            -PercentComplete (100 * ($i - 1) / [Math]::Max(1, $servers.Count))

        $entries = @()
        try {
            $uri = "$arm$($server.Id)/configurations?api-version=2023-12-30"
            # Paged defensively: a current server returns all 438 in one page with no nextLink,
            # but a future api-version that pages would otherwise truncate silently.
            while ($uri) {
                $response = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
                $entries += @($response.value)
                $uri = $response.nextLink
            }
        }
        catch {
            # OMITTED AND SAID OUT LOUD, never reported as a server with no parameters.
            $unreadable++
            Write-Warning "Could not read parameters for '$($server.Name)', so it is MISSING from this output rather than reported as having none: $($_.Exception.Message)"
            continue
        }

        foreach ($entry in $entries) {
            $p = $entry.properties
            if ($Name) {
                $matched = $false
                foreach ($pattern in $Name) {
                    if ($entry.name -like $pattern) { $matched = $true; $matchedPattern[$pattern] = $true }
                }
                if (-not $matched) { continue }
            }

            $source = [string] $p.source
            $isOverride = $source -eq 'user-override'
            if ($UserOverride -and -not $isOverride) { continue }

            # STRING COMPARISON, NOT [bool]. [bool] 'False' is $true - see the help.
            $readOnly = ([string] $p.isReadOnly) -eq 'True'
            $pending  = ([string] $p.isConfigPendingRestart) -eq 'True'

            [PSCustomObject]@{
                PSTypeName        = 'MsecMySqlConfiguration'
                ServerName        = [string] $server.Name
                ResourceGroupName = [string] $server.ResourceGroupName
                SubscriptionName  = [string] $server.SubscriptionName
                ServerVersion     = [string] $server.Version
                Parameter         = [string] $entry.name
                # What will apply; CurrentValue is what the engine is running right now.
                Value             = [string] $p.value
                CurrentValue      = [string] $p.currentValue
                DefaultValue      = [string] $p.defaultValue
                # The authoritative "someone changed this" signal - NOT Value -ne DefaultValue.
                Source            = $source
                IsUserOverride    = $isOverride
                # Parsed from the string the API sends, so callers get a real boolean.
                IsReadOnly        = $readOnly
                PendingRestart    = $pending
                DataType          = [string] $p.dataType
                AllowedValues     = [string] $p.allowedValues
                Description       = [string] $p.description
                DocumentationLink = [string] $p.documentationLink
                SubscriptionId    = [string] $server.SubscriptionId
                Id                = [string] $entry.id
            }
        }
    }

    Write-Progress -Id 1840 -Activity 'Reading MySQL server parameters' -Completed

    # SAID OUT LOUD, because an empty result from a typo is indistinguishable from an empty
    # result from a clean estate. A work item once shipped with '-Name version' as its
    # reproduce command: it returns nothing, because the engine version is a property of the
    # server and not one of its parameters, and a reader would have taken the silence for
    # "no problem here".
    $missed = @($matchedPattern.Keys | Where-Object { -not $matchedPattern[$_] })
    if ($missed.Count) {
        Write-Warning ("No parameter matched: $($missed -join ', '). -Name is a wildcard filter over " +
            "MySQL SERVER PARAMETERS, so an unmatched name returns nothing rather than failing. " +
            "An empty result here means NO MATCH, not 'no deviation'. Run without -Name to see " +
            'what exists, and note that server properties such as the engine version are not ' +
            'parameters - Search-MsecAzureResourceGraph -ResourceType MySQL has those.')
    }

    if ($unreadable -gt 0) {
        Write-Warning "$unreadable server(s) could not be read and are absent from this output. Check Reader access on them before concluding anything about the estate."
    }
}
