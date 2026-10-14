#Requires -Module Pester
#
# Tests for Get-MsecMySqlConfiguration.
#
# The traps, all found by calling the live endpoint before writing the command:
#
#   EVERY BOOLEAN ON THIS ENDPOINT IS A STRING, and [bool] 'False' is $true in PowerShell. A
#   cast instead of a string comparison turns every read-only parameter into a settable one,
#   silently and with no error. 162 of 438 parameters on a current server are read-only.
#
#   SOURCE, NOT VALUE-VERSUS-DEFAULT, SAYS WHETHER SOMEONE CHANGED A PARAMETER. Measured:
#   require_secure_transport with Value 'ON' and DefaultValue 'ON' and Source 'user-override'.
#   A deviation report built on Value -ne DefaultValue misses it.
#
#   A SERVER WHOSE PARAMETERS CANNOT BE READ MUST NOT LOOK LIKE A SERVER WITH NONE. It is
#   warned about and omitted.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop

    $script:StubbedAz = @()
    $azStubs = @{
        'Get-AzContext'     = { [CmdletBinding()] param() }
        'Get-AzAccessToken' = { [CmdletBinding()] param($ResourceUrl) }
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
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecMySqlConfiguration' {

    BeforeAll {
        # Shaped exactly like the live endpoint: every boolean is a STRING.
        function New-Entry {
            param($Name, $Value, $Default, $Source, $ReadOnly = 'False', $Pending = 'False', $Current = $null)
            [pscustomobject]@{
                name = $Name
                id   = "/subscriptions/s1/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/db1/configurations/$Name"
                properties = [pscustomobject]@{
                    value                  = $Value
                    currentValue           = if ($null -ne $Current) { $Current } else { $Value }
                    defaultValue           = $Default
                    source                 = $Source
                    isReadOnly             = $ReadOnly
                    isConfigPendingRestart = $Pending
                    dataType               = 'Enumeration'
                    allowedValues          = 'ON,OFF'
                    description            = "about $Name"
                    documentationLink      = 'https://example.invalid'
                }
            }
        }
    }

    BeforeEach {
        InModuleScope Msec {
            Mock Get-AzContext       -MockWith { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 's1' } } }
            Mock Get-AzAccessToken   -MockWith { [pscustomobject]@{ Token = 'tok' } }
            Mock Get-MsecEnvironment -MockWith { [pscustomobject]@{ ArmResource = 'https://management.azure.com' } }
            Mock Search-MsecAzureResourceGraph -MockWith {
                @([pscustomobject]@{
                    Name = 'db1'; ResourceGroupName = 'rg'; SubscriptionName = 'PROD'
                    SubscriptionId = 's1'; Version = '8.4'
                    Id = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.DBforMySQL/flexibleServers/db1'
                })
            }
        }
    }

    It "reads isReadOnly as a string - [bool] 'False' is \$true and would inverse every row" {
        $entries = @(
            (New-Entry -Name 'binlog_encryption'        -Value 'OFF' -Default 'OFF' -Source 'system-default' -ReadOnly 'True'),
            (New-Entry -Name 'require_secure_transport' -Value 'ON'  -Default 'ON'  -Source 'user-override'  -ReadOnly 'False')
        )
        $rows = InModuleScope Msec -Parameters @{ Entries = $entries } {
            # Assigned into module scope: a -Parameters variable is NOT in scope when the mock
            # body below actually runs. Same trap as the Intune tests.
            $script:Entries = $Entries
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = $script:Entries } }
            Get-MsecMySqlConfiguration
        }

        ($rows | Where-Object Parameter -eq 'binlog_encryption').IsReadOnly        | Should -BeTrue
        ($rows | Where-Object Parameter -eq 'require_secure_transport').IsReadOnly | Should -BeFalse
    }

    It 'treats Source as the deviation signal, not Value versus DefaultValue' {
        # REGRESSION. require_secure_transport is the real case: ON, default ON, and explicitly
        # set by a person. Value -ne DefaultValue is $false here, so a report built that way
        # lists nothing and concludes nobody has touched the server.
        $entries = @(
            (New-Entry -Name 'require_secure_transport' -Value 'ON'  -Default 'ON'  -Source 'user-override'),
            (New-Entry -Name 'default_table_encryption' -Value 'OFF' -Default 'OFF' -Source 'system-default')
        )
        $rows = InModuleScope Msec -Parameters @{ Entries = $entries } {
            $script:Entries = $Entries
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = $script:Entries } }
            Get-MsecMySqlConfiguration -UserOverride
        }

        @($rows).Count       | Should -Be 1
        $rows[0].Parameter   | Should -Be 'require_secure_transport'
        # The point of the test: the two values are identical and it is still an override.
        $rows[0].Value       | Should -Be $rows[0].DefaultValue
        $rows[0].IsUserOverride | Should -BeTrue
    }

    It 'keeps Value and CurrentValue apart when a restart is pending' {
        # Value is what will apply; CurrentValue is what the engine is running. Collapsing them
        # claims a control is in force before the server has picked it up.
        $entries = @(
            (New-Entry -Name 'require_secure_transport' -Value 'ON' -Default 'ON' -Source 'user-override' -Pending 'True' -Current 'OFF')
        )
        $rows = InModuleScope Msec -Parameters @{ Entries = $entries } {
            $script:Entries = $Entries
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = $script:Entries } }
            Get-MsecMySqlConfiguration
        }

        $rows[0].Value          | Should -Be 'ON'
        $rows[0].CurrentValue   | Should -Be 'OFF'
        $rows[0].PendingRestart | Should -BeTrue
    }

    It 'filters parameters by wildcard, client-side' {
        $entries = @(
            (New-Entry -Name 'tls_version'              -Value 'TLSv1.2' -Default 'TLSv1.2,TLSv1.3' -Source 'user-override'),
            (New-Entry -Name 'max_connections'          -Value '10923'   -Default '10923'           -Source 'system-default'),
            (New-Entry -Name 'default_table_encryption' -Value 'OFF'     -Default 'OFF'             -Source 'system-default')
        )
        $rows = InModuleScope Msec -Parameters @{ Entries = $entries } {
            $script:Entries = $Entries
            Mock Invoke-RestMethod -MockWith { [pscustomobject]@{ value = $script:Entries } }
            Get-MsecMySqlConfiguration -Name 'tls_*', '*encrypt*'
        }

        @($rows).Count | Should -Be 2
        @($rows.Parameter) | Should -Not -Contain 'max_connections'
    }

    It 'warns and omits a server whose parameters cannot be read, rather than reporting none' {
        InModuleScope Msec {
            Mock Invoke-RestMethod -MockWith { throw 'Forbidden' }
            $rows = Get-MsecMySqlConfiguration -WarningVariable w -WarningAction SilentlyContinue
            $script:capturedRows = @($rows)
            $script:capturedWarn = "$w"
        }
        $rows = InModuleScope Msec { $script:capturedRows }
        $warn = InModuleScope Msec { $script:capturedWarn }

        @($rows).Count | Should -Be 0
        $warn | Should -Match 'MISSING from this output'
    }

    It 'follows nextLink so a paged response is not silently truncated' {
        $p1 = @(New-Entry -Name 'a' -Value '1' -Default '1' -Source 'system-default')
        $p2 = @(New-Entry -Name 'b' -Value '2' -Default '2' -Source 'system-default')
        $rows = InModuleScope Msec -Parameters @{ P1 = $p1; P2 = $p2 } {
            $script:P1 = $P1; $script:P2 = $P2; $script:Page = 0
            Mock Invoke-RestMethod -MockWith {
                $script:Page++
                if ($script:Page -eq 1) {
                    [pscustomobject]@{ value = $script:P1; nextLink = 'https://management.azure.com/page2' }
                }
                else { [pscustomobject]@{ value = $script:P2 } }
            }
            Get-MsecMySqlConfiguration
        }

        @($rows).Count     | Should -Be 2
        @($rows.Parameter) | Should -Contain 'b'
    }

    It 'throws, naming the cause, when there is no Azure context' {
        InModuleScope Msec {
            Mock Get-AzContext -MockWith { $null }
            { Get-MsecMySqlConfiguration } | Should -Throw '*runs as you, not as the msec app*'
        }
    }
}
