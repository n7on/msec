function Invoke-MsecLogAnalyticsSearch {
    <#
    .SYNOPSIS
        Runs a KQL query against a Basic- or Auxiliary-plan table through the Log Analytics
        /search endpoint - the only endpoint that accepts them.

    .DESCRIPTION
        A BASIC TABLE IS REFUSED BY THE QUERY ENDPOINT, AND IT IS NOT A PERMISSION PROBLEM.
        The API that Invoke-AzOperationalInsightsQuery posts to - /v1/workspaces/{id}/query -
        rejects any query touching a Basic-plan table with BadArgumentError /
        UnsupportedApiQueryValidationError, and names /v1/workspaces/{id}/search as the
        endpoint to use instead. Same host, same token, same request body; a different path.

        Measured against a live workspace: an Application Gateway access-log table on the
        Basic plan failed on /query for 'take 1' and returned rows on /search for the same
        KQL - summarize included, which the Basic-logs operator restrictions had suggested
        would not work.

        VALUES ARE RETURNED AS STRINGS ON PURPOSE. /search types its columns, where
        Invoke-AzOperationalInsightsQuery surfaces everything as a string.
        Search-MsecLogAnalytics documents the string contract, so honouring the typed columns
        here would make one command return two different shapes depending on a switch - the
        caller would have to know which endpoint answered before trusting a comparison. A
        JSON null stays $null rather than becoming '': "no value" and "empty string" are
        different answers.

        A COLUMN THAT IS NOT A SCALAR BECOMES COMPACT JSON, not the result of [string] on an
        object, which would render 'System.Object[]' and quietly destroy a dynamic column.

        BILLED PER GB SCANNED. Basic-plan queries are charged on data scanned rather than
        rows returned, so the caller's timespan is passed through unchanged and never
        widened.

    .PARAMETER CustomerId
        The workspace GUID (customerId), not the ARM resource id.

    .PARAMETER Query
        KQL. Must reference the Basic table by name.

    .PARAMETER Timespan
        The query window, sent as an ISO 8601 duration. Required - see the billing note.

    .OUTPUTS
        One PSCustomObject per row, properties named for the projected columns.

    .NOTES
        Runs on the Az context, like the rest of Search-MsecLogAnalytics - the data-plane
        token's audience is the Log Analytics endpoint for the current cloud. Needs the same
        workspace read permission as an Analytics-plan query; verified against a live
        workspace with no additional rights granted.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]   $CustomerId,
        [Parameter(Mandatory)] [string]   $Query,
        [Parameter(Mandatory)] [timespan] $Timespan
    )

    $endpoint = (Get-MsecEnvironment).OperationalInsightsResource

    $tokenResponse = Get-AzAccessToken -ResourceUrl $endpoint -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }

    $body = @{
        query    = $Query
        timespan = [System.Xml.XmlConvert]::ToString($Timespan)
    } | ConvertTo-Json -Depth 3

    $requestArgs = @{
        Method      = 'POST'
        Uri         = "$endpoint/v1/workspaces/$CustomerId/search"
        Headers     = @{ Authorization = "Bearer $token" }
        ContentType = 'application/json'
        Body        = $body
        ErrorAction = 'Stop'
    }

    Write-Verbose "Basic-plan query via $($requestArgs.Uri), timespan $($Timespan)."

    $response = Invoke-MsecRetryableRequest -RequestArgs $requestArgs -What 'Log Analytics'

    $table = @($response.tables)[0]
    if (-not $table) { return }

    $names = @($table.columns | ForEach-Object { $_.name })

    foreach ($row in @($table.rows)) {
        $obj = [ordered]@{}
        for ($i = 0; $i -lt $names.Count; $i++) {
            $value = $row[$i]
            $obj[$names[$i]] =
                if ($null -eq $value) { $null }
                elseif ($value -is [string] -or $value -is [valuetype]) { [string] $value }
                else { ConvertTo-Json -InputObject $value -Compress -Depth 10 }
        }
        [pscustomobject] $obj
    }
}
