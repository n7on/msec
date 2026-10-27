function Resolve-MsecSentinelWorkspace {
    <#
    .SYNOPSIS
        The Log Analytics workspaces a Sentinel command should act on, with an ARM token and
        the SecurityInsights base URL already built for each.

    .DESCRIPTION
        Shared by the Sentinel commands so they cannot disagree about which workspace a name
        means, or about what a missing one implies.

        NAMED AND NOT FOUND IS AN ERROR, NEVER AN EMPTY RESULT. Building a request URL from an
        empty ResourceId yields '/providers/Microsoft.SecurityInsights/...' with no scope at
        all, which Azure rejects as an authorization failure - sending the reader to check RBAC
        for a workspace that was never located.

    .PARAMETER SubscriptionId
        Subscription to switch to first. Defaults to the active Az context.

    .PARAMETER ResourceGroupName
        Narrows the workspace search.

    .PARAMETER WorkspaceName
        A single workspace. Without it every workspace in scope is returned, and the caller
        decides what to do with several.

    .OUTPUTS
        One PSCustomObject with Headers, Subscription and Workspaces; each workspace carries
        Name, ResourceGroupName, ResourceId and Base (the SecurityInsights URL).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $SubscriptionId,
        [string] $ResourceGroupName,
        [string] $WorkspaceName
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-MsecAzure first - Sentinel is an Azure resource, so this reads as you rather than as the msec app.'
    }
    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-Verbose "Switching context to subscription $SubscriptionId"
        $context = Set-AzContext -SubscriptionId $SubscriptionId -Scope Process -ErrorAction Stop
    }
    $subscription = $context.Subscription.Id

    $arm = (Get-MsecEnvironment).ArmResource
    $tokenResponse = Get-AzAccessToken -ResourceUrl "$arm/" -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }

    $workspaceParams = @{ ErrorAction = 'Stop' }
    if ($ResourceGroupName) { $workspaceParams['ResourceGroupName'] = $ResourceGroupName }
    if ($WorkspaceName -and $ResourceGroupName) { $workspaceParams['Name'] = $WorkspaceName }

    # Get-AzOperationalInsightsWorkspace throws a bare "Operation returned an invalid status
    # code 'NotFound'" for a name that does not exist, naming neither the name nor the
    # subscription. Caught so the message below is the one the reader sees.
    $workspaces = @()
    try { $workspaces = @(Get-AzOperationalInsightsWorkspace @workspaceParams) }
    catch {
        if ("$($_.Exception.Message)" -notmatch 'NotFound|ResourceNotFound') { throw }
        Write-Verbose "Workspace lookup returned NotFound: $($_.Exception.Message)"
    }
    if ($WorkspaceName) { $workspaces = @($workspaces | Where-Object { $_.Name -eq $WorkspaceName }) }

    if (-not $workspaces.Count) {
        $where = @(
            if ($WorkspaceName)     { "workspace '$WorkspaceName'" }
            if ($ResourceGroupName) { "resource group '$ResourceGroupName'" }
        ) -join ' in '
        if ($where) {
            throw "No Log Analytics $where found in subscription $subscription. Check the name, and that the active context is the right subscription - Get-AzContext shows which."
        }
        Write-Warning "No Log Analytics workspaces found in subscription $subscription. This is not the same as a Sentinel with no incidents."
    }

    [PSCustomObject]@{
        Headers      = @{ Authorization = "Bearer $token" }
        Subscription = $subscription
        Workspaces   = @($workspaces | ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                ResourceGroupName = $_.ResourceGroupName
                ResourceId        = $_.ResourceId
                Base              = "$arm$($_.ResourceId)/providers/Microsoft.SecurityInsights"
            }
        })
    }
}
