BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psd1') -Force

    # Defined here, not in the Describe body: a discovery-time variable is gone by the time an
    # It runs, which reads as the command returning nothing rather than as a test bug.
    $script:Devices = @(
        [pscustomobject]@{ Id = 'd-stale'; DeviceName = 'VIE0001'; Os = 'Windows'
                           UserPrincipalName = 'a@contoso.com'; ComplianceState = 'noncompliant'
                           LastSyncDateTime = (Get-Date).AddDays(-200) }
        [pscustomobject]@{ Id = 'd-secfail'; DeviceName = 'VIE0002'; Os = 'Windows'
                           UserPrincipalName = 'b@contoso.com'; ComplianceState = 'noncompliant'
                           LastSyncDateTime = (Get-Date).AddDays(-1) }
        [pscustomobject]@{ Id = 'd-silent'; DeviceName = 'VIE0003'; Os = 'Windows'
                           UserPrincipalName = 'c@contoso.com'; ComplianceState = 'noncompliant'
                           LastSyncDateTime = (Get-Date).AddDays(-5) }
        [pscustomobject]@{ Id = 'd-ok'; DeviceName = 'VIE0004'; Os = 'Windows'
                           UserPrincipalName = 'd@contoso.com'; ComplianceState = 'compliant'
                           LastSyncDateTime = (Get-Date).AddDays(-1) }
    )
}

Describe 'Get-MsecIntuneDeviceCompliance' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession {}
            Mock Write-Progress {}

            # Assigned into the MODULE's script scope, not closed over. A mock body runs when
            # the mock is invoked, by which time an InModuleScope -Parameters variable has
            # gone out of scope and reads as $null - which looks exactly like the command
            # returning nothing.
            $script:TestDevices = @(
                [pscustomobject]@{ Id = 'd-stale'; DeviceName = 'VIE0001'; Os = 'Windows'
                                   UserPrincipalName = 'a@contoso.com'; ComplianceState = 'noncompliant'
                                   LastSyncDateTime = (Get-Date).AddDays(-200) }
                [pscustomobject]@{ Id = 'd-secfail'; DeviceName = 'VIE0002'; Os = 'Windows'
                                   UserPrincipalName = 'b@contoso.com'; ComplianceState = 'noncompliant'
                                   LastSyncDateTime = (Get-Date).AddDays(-1) }
                [pscustomobject]@{ Id = 'd-silent'; DeviceName = 'VIE0003'; Os = 'Windows'
                                   UserPrincipalName = 'c@contoso.com'; ComplianceState = 'noncompliant'
                                   LastSyncDateTime = (Get-Date).AddDays(-5) }
                [pscustomobject]@{ Id = 'd-ok'; DeviceName = 'VIE0004'; Os = 'Windows'
                                   UserPrincipalName = 'd@contoso.com'; ComplianceState = 'compliant'
                                   LastSyncDateTime = (Get-Date).AddDays(-1) }
            )
            Mock Get-MsecIntuneDevice { $script:TestDevices }

            Mock Invoke-MsecGraphRequest {
                # Policy states.
                if ($Path -match '/managedDevices/d-stale/deviceCompliancePolicyStates$') {
                    return @(@{ id = 'p-default'; displayName = 'Default Device Compliance Policy'; state = 'nonCompliant' })
                }
                if ($Path -match '/managedDevices/d-secfail/deviceCompliancePolicyStates$') {
                    return @(@{ id = 'p-base'; displayName = 'Baseline Windows'; state = 'nonCompliant' })
                }
                # Flagged non-compliant, but no failing policy comes back at all.
                if ($Path -match '/managedDevices/d-silent/deviceCompliancePolicyStates$') { return @() }
                if ($Path -match '/managedDevices/d-ok/deviceCompliancePolicyStates$') { return @() }

                # Setting states.
                if ($Path -match 'p-default/settingStates') {
                    return @(
                        @{ settingName = 'DefaultDeviceCompliancePolicy.RequireRemainContact'; state = 'nonCompliant'; setting = '' }
                        @{ settingName = 'DefaultDeviceCompliancePolicy.RequireUserExistence'; state = 'compliant'; setting = '' }
                    )
                }
                if ($Path -match 'p-base/settingStates') {
                    return @(@{ settingName = 'BitLockerEnabled'; state = 'nonCompliant'; setting = '' })
                }
                return @()
            }
        }
    }

    It 'separates a housekeeping failure from a real security control' {
        # THE POINT OF THE COMMAND. The built-in default policy checks whether the device has
        # checked in and whether its owner still exists - a device failing those is stale, not
        # insecure, and reporting both as 'non-compliant' is how a real failure gets buried.
        InModuleScope msec {
            $r = Get-MsecIntuneDeviceCompliance
            ($r | Where-Object DeviceName -eq 'VIE0001').Category | Should -Be 'Housekeeping'
            ($r | Where-Object DeviceName -eq 'VIE0002').Category | Should -Be 'SecurityControl'
        }
    }

    It '-SecurityOnly drops housekeeping but KEEPS rows it could not attribute' {
        # Unattributed survives the filter deliberately: an unreadable reason might be a
        # security failure, and the view someone uses to hunt for those is the worst possible
        # place for it to disappear from. Confirmed-only is Where-Object Category.
        InModuleScope msec {
            $r = Get-MsecIntuneDeviceCompliance -SecurityOnly
            $r.DeviceName | Should -Be @('VIE0002', 'VIE0003')
            ($r | Where-Object Category -eq 'SecurityControl').Setting | Should -Be @('BitLockerEnabled')
            ($r | Where-Object Category -eq 'Housekeeping')            | Should -BeNullOrEmpty
        }
    }

    It 'reports a non-compliant device whose reason cannot be read, rather than dropping it' {
        # Measured on a live tenant: 4 of 33 devices returned no failing policy at all.
        # Omitting them shrinks the apparent problem, and 'we could not tell why' must never
        # look like 'there is nothing wrong'.
        InModuleScope msec {
            $row = Get-MsecIntuneDeviceCompliance | Where-Object DeviceName -eq 'VIE0003'
            $row          | Should -Not -BeNullOrEmpty
            $row.Category | Should -Be 'Unattributed'
            $row.Setting  | Should -BeNullOrEmpty
        }
    }

    It 'reads settingName rather than the always-empty setting property' {
        # v1.0 returns 'setting' present and blank on every row; the readable rule is in
        # 'settingName'. Reading the obvious one yields a column of blanks.
        InModuleScope msec {
            (Get-MsecIntuneDeviceCompliance | Where-Object DeviceName -eq 'VIE0002').Setting |
                Should -Be 'BitLockerEnabled'
        }
    }

    It 'skips compliant devices by default, because each one costs two Graph calls' {
        InModuleScope msec {
            (Get-MsecIntuneDeviceCompliance).DeviceName | Should -Not -Contain 'VIE0004'
            Should -Invoke Invoke-MsecGraphRequest -Times 0 -Exactly -ParameterFilter {
                $Path -match 'd-ok'
            }
        }
    }

    It '-IncludeCompliant evaluates them too' {
        InModuleScope msec {
            Get-MsecIntuneDeviceCompliance -IncludeCompliant | Out-Null
            Should -Invoke Invoke-MsecGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Path -match 'd-ok/deviceCompliancePolicyStates$'
            }
        }
    }

    It 'only emits rows for settings that actually failed' {
        # RequireUserExistence is compliant on the stale device and must not appear as a
        # reason it is non-compliant.
        InModuleScope msec {
            $r = Get-MsecIntuneDeviceCompliance | Where-Object DeviceName -eq 'VIE0001'
            @($r).Count | Should -Be 1
            $r.Setting  | Should -Be 'DefaultDeviceCompliancePolicy.RequireRemainContact'
        }
    }

    It 'carries DaysQuiet, because an unreachable device cannot be remediated at all' {
        InModuleScope msec {
            $r = Get-MsecIntuneDeviceCompliance | Where-Object DeviceName -eq 'VIE0001'
            $r.DaysQuiet | Should -BeGreaterThan 190
        }
    }

    It '-DeviceName filters before doing any work' {
        InModuleScope msec {
            (Get-MsecIntuneDeviceCompliance -DeviceName 'VIE0002').DeviceName | Should -Be @('VIE0002')
            Should -Invoke Invoke-MsecGraphRequest -Times 0 -Exactly -ParameterFilter {
                $Path -match 'd-stale'
            }
        }
    }

    It 'names the missing permission when Graph refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecIntuneDeviceCompliance } | Should -Throw '*DeviceManagementManagedDevices.Read.All*'
        }
    }


    It 'reports a THROTTLED read as Unreadable, not as a clean or unattributed device' {
        # The defect this distinction fixes. Intune throttles two-calls-per-device hard, the
        # Graph helper gives up after 5 retries, and the original code caught that and
        # emitted the device as though nothing could be found wrong with it. Measured: the
        # same tenant returned 4 unattributed devices on one run and 9 on the next, purely
        # because the 429s landed on different devices - and one of the 'unattributed' ones
        # had three perfectly readable settings when queried on its own.
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest {
                if ($Path -match 'd-stale') { throw 'Response status code does not indicate success: 429 (TooManyRequests).' }
                if ($Path -match '/managedDevices/d-secfail/deviceCompliancePolicyStates$') {
                    return @(@{ id = 'p-base'; displayName = 'Baseline Windows'; state = 'nonCompliant' })
                }
                if ($Path -match 'p-base/settingStates') {
                    return @(@{ settingName = 'BitLockerEnabled'; state = 'nonCompliant'; setting = '' })
                }
                return @()
            }
            $warnings = @()
            $r = Get-MsecIntuneDeviceCompliance -WarningVariable warnings -WarningAction SilentlyContinue
            ($r | Where-Object DeviceName -eq 'VIE0001').Category | Should -Be 'Unreadable'
            # VIE0003 genuinely returns nothing - that stays Unattributed, so the two
            # remain distinguishable.
            ($r | Where-Object DeviceName -eq 'VIE0003').Category | Should -Be 'Unattributed'
            ($warnings -join ' ') | Should -Match 'throttl'
        }
    }
    It 'emits the documented type so the table view applies' {
        InModuleScope msec {
            (Get-MsecIntuneDeviceCompliance)[0].PSObject.TypeNames |
                Should -Contain 'MsecIntuneDeviceCompliance'
        }
    }
}
