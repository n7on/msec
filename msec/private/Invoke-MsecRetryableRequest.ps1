function Invoke-MsecRetryableRequest {
    <#
    .SYNOPSIS
        Invoke-RestMethod with throttling and transient-error retries, honouring Retry-After.

    .DESCRIPTION
        Shared so Graph and ARM throttle the same way, rather than each growing its own
        slightly different loop.

        429, 503 AND 504 ARE RETRIED; NOTHING ELSE IS. Retrying a 403 or a 404 cannot help and
        only delays a message the caller needs now, so every other status is rethrown
        untouched.

        RETRY-AFTER IS AUTHORITATIVE WHERE PRESENT, with capped exponential backoff as the
        fallback. The header's shape varies by platform and exception type, so reading it is
        guarded and failure to parse it simply falls through to backoff.

        BOUNDED ON PURPOSE. A persistently throttled call surfaces as an error rather than
        hanging forever - a bulk operation that never finishes is worse than one that stops
        and says why.

        WHY IT MATTERS FOR ARM: closing a few hundred Sentinel incidents is one PUT each, and
        ARM throttles per subscription. Reported from a live bulk close of 240 incidents - one
        write hit a 429. Without this, that arrives mid-run as a hard failure with some
        incidents written and some not, which is the worst state to resume from.

    .PARAMETER RequestArgs
        Splat for Invoke-RestMethod. Passed through untouched.

    .PARAMETER MaxAttempts
        Total attempts including the first. Default 5.

    .PARAMETER What
        Name used in the verbose line, e.g. 'Microsoft Graph' or 'Azure Resource Manager'.

    .OUTPUTS
        Whatever Invoke-RestMethod returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $RequestArgs,
        [int] $MaxAttempts = 5,
        [string] $What = 'The service'
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod @RequestArgs
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int] $_.Exception.Response.StatusCode
            }

            $throttled = ($status -in 429, 503, 504) -or
                         ($_.Exception.Message -match '\b(429|503|504)\b|Too Many Requests|Service Unavailable')

            if (-not $throttled -or $attempt -ge $MaxAttempts) { throw }

            $wait = 0
            try {
                $retryAfter = $_.Exception.Response.Headers.RetryAfter
                if ($retryAfter) {
                    if ($retryAfter.Delta) { $wait = [int] $retryAfter.Delta.TotalSeconds }
                    elseif ("$retryAfter" -match '^\d+$') { $wait = [int] "$retryAfter" }
                }
            }
            catch {
                # Header shapes vary by platform and exception type; backoff covers it.
            }
            if ($wait -le 0) { $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) }

            Write-Verbose "$What throttled this request (status $status). Waiting $wait s, then retry $attempt of $($MaxAttempts - 1): $($RequestArgs.Uri)"
            Start-Sleep -Seconds $wait
        }
    }
}
