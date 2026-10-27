#Requires -Module Pester
#
# Tests for Invoke-MsecRetryableRequest - the shared throttling retry used by both the Graph
# and the ARM callers.
#
# The traps:
#
#   RETRYING THE WRONG STATUS WASTES TIME AND HIDES THE MESSAGE. 403 and 404 cannot be fixed
#   by waiting, so they must surface immediately.
#
#   AN UNBOUNDED RETRY IS WORSE THAN A FAILURE. A bulk operation that never finishes cannot be
#   resumed from; one that stops and says why can.
#
#   Start-Sleep IS MOCKED THROUGHOUT, so the suite does not actually wait.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module Msec -Force -ErrorAction SilentlyContinue }

Describe 'Invoke-MsecRetryableRequest' {

    It 'retries a 429 and returns the eventual success' {
        # THE BUG THIS PREVENTS. Closing a few hundred Sentinel incidents is one PUT each and
        # ARM throttles per subscription - reported from a live run of 240, one write was
        # throttled. Without a retry that lands mid-run with some written and some not.
        $r = InModuleScope Msec {
            Mock Start-Sleep -MockWith { }
            $script:N = 0
            Mock Invoke-RestMethod -MockWith {
                $script:N++
                if ($script:N -lt 3) { throw 'Response status code does not indicate success: 429 (Too Many Requests).' }
                [pscustomobject]@{ ok = $true; attempts = $script:N }
            }
            Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' }
        }

        $r.ok       | Should -BeTrue
        $r.attempts | Should -Be 3
    }

    It 'retries 503 and 504 as well, which are transient by the services own guidance' {
        foreach ($code in '503 (Service Unavailable)', '504 (Gateway Timeout)') {
            $r = InModuleScope Msec -Parameters @{ code = $code } {
                param($code)
                Mock Start-Sleep -MockWith { }
                $script:N = 0
                Mock Invoke-RestMethod -MockWith {
                    $script:N++
                    if ($script:N -lt 2) { throw "Response status code does not indicate success: $code." }
                    [pscustomobject]@{ attempts = $script:N }
                }
                Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' }
            }
            $r.attempts | Should -Be 2 -Because "$code is transient and should be retried"
        }
    }

    It 'does NOT retry a 403, because waiting cannot grant a permission' {
        # Retrying here would delay a message the caller needs now, four times over.
        $n = InModuleScope Msec {
            Mock Start-Sleep -MockWith { }
            $script:N = 0
            Mock Invoke-RestMethod -MockWith {
                $script:N++
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            try { Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' } | Out-Null } catch { }
            $script:N
        }

        $n | Should -Be 1
    }

    It 'gives up after MaxAttempts rather than retrying forever' {
        $n = InModuleScope Msec {
            Mock Start-Sleep -MockWith { }
            $script:N = 0
            Mock Invoke-RestMethod -MockWith {
                $script:N++
                throw 'Response status code does not indicate success: 429 (Too Many Requests).'
            }
            try { Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' } -MaxAttempts 3 | Out-Null } catch { }
            $script:N
        }

        $n | Should -Be 3
    }

    It 'rethrows the original error when it gives up, not a wrapper' {
        # The caller's 403/429 handling keys on the message; swallowing it would break the
        # messages the Sentinel commands build from it.
        $msg = InModuleScope Msec {
            Mock Start-Sleep -MockWith { }
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 429 (Too Many Requests).' }
            try { Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' } -MaxAttempts 2 | Out-Null } catch { $_.Exception.Message }
        }

        $msg | Should -BeLike '*429*'
    }

    It 'backs off between attempts, capped so one bad call cannot stall a run' {
        $waits = InModuleScope Msec {
            $script:Waits = @()
            Mock Start-Sleep -MockWith { $script:Waits += $Seconds }
            Mock Invoke-RestMethod -MockWith { throw 'Response status code does not indicate success: 429 (Too Many Requests).' }
            try { Invoke-MsecRetryableRequest -RequestArgs @{ Uri = 'https://example.invalid' } -MaxAttempts 5 | Out-Null } catch { }
            $script:Waits
        }

        @($waits).Count | Should -Be 4
        ($waits | Measure-Object -Maximum).Maximum | Should -BeLessOrEqual 30
    }
}
