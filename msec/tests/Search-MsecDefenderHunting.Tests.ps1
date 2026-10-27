#Requires -Module Pester
#
# Tests for Search-MsecDefenderHunting.
#
# The things worth pinning are the ones that make a hunting result trustworthy rather than
# merely present:
#
#   The window goes to the API as its own timespan, so the .kql files carry no ago() - one file
#   serves every window, and nothing silently intersects with what the caller asked for.
#
#   A BARE INTEGER -Timespan is TICKS. -Timespan 7 means 700 nanoseconds, so the query returns
#   nothing and reads as "there was nothing to find" - the single most dangerous way for a
#   security query to be wrong.
#
#   A table belonging to an un-onboarded product FAILS TO RESOLVE rather than returning zero
#   rows. Translating that into a plain sentence is the point: "0 results" and "this product is
#   not installed" must never look alike.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Search-MsecDefenderHunting' {

    BeforeEach {
        InModuleScope msec { $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} } }
    }

    It 'refuses without a session' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Search-MsecDefenderHunting -Subject Alert } | Should -Throw '*Connect-Msec*'
        }
    }

    It 'sends the bundled file and a whole-day ISO window' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:captured = $Body
                @{ results = @(); schema = @() }
            }
            $null = Search-MsecDefenderHunting -Subject SignIn -Name Failed -Days 3
            $script:captured
        }

        $sent['Timespan'] | Should -Be 'P3D'
        $sent['Query']    | Should -Match 'AADSignInEventsBeta'
        $sent['Query']    | Should -Match 'ErrorCode != 0'
    }

    It 'defaults to seven days' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Subject Alert
            $script:captured
        }
        $sent['Timespan'] | Should -Be 'P7D'
    }

    It 'converts a sub-day -Timespan to hours and minutes' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Subject Alert -Timespan 04:30:00
            $script:captured
        }
        $sent['Timespan'] | Should -Be 'PT4H30M'
    }

    It 'refuses a bare-integer -Timespan, which PowerShell reads as ticks' {
        { Search-MsecDefenderHunting -Subject Alert -Timespan 7 } |
            Should -Throw '*read as TICKS*'
    }

    It 'refuses a window past the stores retention' {
        { Search-MsecDefenderHunting -Subject Alert -Days 90 } | Should -Throw
    }

    It 'runs literal KQL without touching the bundled files' {
        $sent = InModuleScope msec {
            $script:captured = $null
            Mock Invoke-MsecGraphRequest -MockWith { $script:captured = $Body; @{ results = @() } }
            $null = Search-MsecDefenderHunting -Query 'DeviceInfo | take 1' -Days 1
            $script:captured
        }
        $sent['Query'] | Should -Be 'DeviceInfo | take 1'
    }

    It 'names a missing .kql rather than running something else' {
        { Search-MsecDefenderHunting -Subject SignIn -Name NoSuchQuery } |
            Should -Throw '*NoSuchQuery.kql*'
    }

    It 'translates an unresolved table into "not onboarded", not zero rows' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                throw "Failed to resolve table or column expression named 'CloudAppEvents'"
            }
            { Search-MsecDefenderHunting -Query 'CloudAppEvents | count' } |
                Should -Throw '*not onboarded or not licensed*'
        }
    }

    It 'emits one object per result row' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @{ results = @(@{ Severity = 'High'; n = '83' }, @{ Severity = 'Low'; n = '126' }) }
            }
            @(Search-MsecDefenderHunting -Query 'AlertInfo | count')
        }
        $rows.Count       | Should -Be 2
        $rows[0].Severity | Should -Be 'High'
    }
}

Describe 'kql/Hunting bundled queries' {
    BeforeAll {
        $script:HuntRoot = Join-Path (Get-Module msec).ModuleBase 'kql/Hunting'
        $script:HuntFiles = @(Get-ChildItem -LiteralPath $script:HuntRoot -Filter *.kql -File -Recurse)
    }

    It 'carries no time filter - the window belongs to -Days' {
        # Same rule as kql/Law: the window is a server-side parameter, and one baked into a file
        # is invisible at the call site and intersects silently with what was asked for.
        $offenders = $script:HuntFiles | ForEach-Object {
            $code = ((Get-Content -LiteralPath $_.FullName) | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
            if ($code -match '\bago\s*\(' -or $code -match 'Timestamp\s*[<>]') { $_.Name }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'gives every subject an All.kql, which is the default -Name' {
        foreach ($dir in Get-ChildItem -LiteralPath $script:HuntRoot -Directory) {
            (Join-Path $dir.FullName 'All.kql') | Should -Exist
        }
    }

    It 'collapses DeviceInfo to one row per device' {
        # DeviceInfo writes a row per device per day. Without arg_max a "device count" counts
        # observations instead, inflating silently with the length of the window.
        $q = Get-Content -LiteralPath (Join-Path $script:HuntRoot 'Device/All.kql') -Raw
        $q | Should -Match 'arg_max\(Timestamp, \*\) by DeviceId'
    }

    It 'says in the file that the vulnerability snapshot ignores the window' {
        # DeviceTvmSoftwareVulnerabilities has no Timestamp column, so -Days cannot apply. The
        # caller has to be told, or an unchanged row count across windows looks like a bug.
        $q = Get-Content -LiteralPath (Join-Path $script:HuntRoot 'Vulnerability/All.kql') -Raw
        $q | Should -Match 'NO Timestamp'
    }
}

Describe 'Search-MsecDefenderHunting result shaping' {

    It 'strips @odata.type annotations, which doubled the columns of every summarize' {
        # THE BUG THIS PREVENTS. The hunting API sends a sibling key per typed value -
        # 'Events@odata.type' = '#Int64' beside 'Events' - so a summarize with two counts came
        # back as four columns and Format-Table was unreadable.
        $r = InModuleScope Msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                @{ results = @(
                    [pscustomobject]@{ 'Rule' = 'AsrUntrustedExecutable'
                                       'Events' = 13; 'Events@odata.type' = '#Int64'
                                       'Devices' = 3; 'Devices@odata.type' = '#Int64' }
                ) }
            }
            Search-MsecDefenderHunting -Query 'DeviceEvents | take 1'
        }

        $names = @($r.PSObject.Properties.Name)
        $names | Should -Contain 'Events'
        $names | Should -Contain 'Devices'
        $names | Should -Not -Contain 'Events@odata.type'
        $names | Should -Not -Contain 'Devices@odata.type'
        $r.Events | Should -Be 13
    }

    It 'keeps every property when the row arrives as a PSCustomObject' {
        # REGRESSION. The first version of the strip read $row.Keys, which is EMPTY on a
        # PSCustomObject - so it silently emitted objects with no properties at all rather
        # than failing, and the result looked like a query that matched nothing.
        $r = InModuleScope Msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                @{ results = @([pscustomobject]@{ A = 'one'; B = 'two'; C = 'three' }) }
            }
            Search-MsecDefenderHunting -Query 'DeviceEvents | take 1'
        }

        @($r.PSObject.Properties.Name).Count | Should -Be 3
        $r.B | Should -Be 'two'
    }
}

Describe 'Hunting/Device/AsrRule.kql' {

    BeforeAll {
        $script:HuntRoot = Join-Path (Get-Module Msec).ModuleBase 'kql/Hunting'
        $script:Asr = Get-Content -LiteralPath (Join-Path $script:HuntRoot 'Device/AsrRule.kql') -Raw
        $script:AsrCode = (($script:Asr -split "`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    }

    It 'carries no time filter, because the window is sent as its own timespan' {
        # A hardcoded ago() would fight the -Days the caller passed, and the API timespan wins -
        # so the file would look like it filtered and would not.
        $script:AsrCode | Should -Not -Match 'ago\('
    }

    It 'splits the outcome from the rule, because they answer different questions' {
        # "Audited" answers "what breaks if I enforce this"; "Blocked" answers "what broke".
        # Defender puts both in one ActionType string - AsrUntrustedExecutableBlocked.
        $script:AsrCode | Should -Match 'Outcome'
        $script:AsrCode | Should -Match 'Audited'
        $script:AsrCode | Should -Match 'Blocked'
        $script:AsrCode | Should -Match 'Rule\s*='
    }

    It 'exposes the window it actually got, so a short one is visible in the result' {
        # Search-MsecDefenderHunting defaults to SEVEN days. Measured on one tenant, the same
        # query returned 8 distinct days by default and 31 with -Days 30 - a four-fold
        # difference in event counts while the caller believed they asked for thirty.
        $script:AsrCode | Should -Match 'FirstSeen'
        $script:AsrCode | Should -Match 'Days\s*='
    }

    It 'counts devices, not only events, because one machine can dominate' {
        $script:AsrCode | Should -Match 'dcount\(DeviceName\)'
    }

    It 'leaves rule and device filtering to the caller' {
        $script:AsrCode | Should -Not -Match '(?i)viedoc|vie0[0-9]'
        $script:AsrCode | Should -Match 'FolderPath'
    }
}

Describe 'Hunting/Device/Process.kql' {

    BeforeAll {
        $script:HuntRoot2 = Join-Path (Get-Module Msec).ModuleBase 'kql/Hunting'
        $raw = Get-Content -LiteralPath (Join-Path $script:HuntRoot2 'Device/Process.kql') -Raw
        $script:ProcCode = (($raw -split "`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    }

    It 'carries no time filter, because the window is sent as its own timespan' {
        $script:ProcCode | Should -Not -Match 'ago\('
    }

    It 'keys identity on the hash, not the file name' {
        # The same FileName covers several builds - measured, 7zG.exe appeared as five
        # distinct SHA256s across five versions in thirty days. Grouping by name alone makes
        # "which version" unanswerable.
        $script:ProcCode | Should -Match 'SHA256'
        $script:ProcCode | Should -Match 'ProcessVersionInfoProductVersion'
    }

    It 'reports Renamed as a string with an empty third state' {
        # A KQL bool arrives through this API as Int64 0/1, so -eq 'True' silently matches
        # nothing. And barely half the events carry an OriginalFileName at all - measured,
        # 5,434,686 of 11,012,759 - so "no" would claim a check that was never possible.
        $script:ProcCode | Should -Match '"yes"'
        $script:ProcCode | Should -Match '"no"'
        $script:ProcCode | Should -Match 'isempty\(OriginalName\)'
        $script:ProcCode | Should -Not -Match 'iff\([^)]*true,\s*false\)'
    }

    It 'strips the extension from both sides before calling something renamed' {
        # Microsoft's own version resources omit it - UsoClient.exe declares "UsoClient" - and
        # comparing raw strings reported 13,523 "renamed" binaries led by Windows components.
        # Stripping the extension cut that to 7,042 genuine base-name differences.
        $script:ProcCode | Should -Match 'trim_end'
        $script:ProcCode | Should -Match 'OrigBase'
    }

    It 'does not treat the declared publisher as a signature' {
        # ProcessVersionInfoCompanyName is a PE version RESOURCE any author can set. Filtering
        # on it inside the query would bake a trust decision into an inventory.
        $script:ProcCode | Should -Not -Match 'Signer\s*(==|!=)\s*"'
        $script:ProcCode | Should -Not -Match 'ProcessVersionInfoCompanyName\s*(==|!=)'
    }
}
