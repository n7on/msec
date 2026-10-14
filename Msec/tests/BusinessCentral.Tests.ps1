#Requires -Module Pester
#
# Tests for Get-MsecBusinessCentralEnvironment and Get-MsecBusinessCentralAccess.
#
# The traps here are all about a value that means "broad" or "unknown" rendering as "narrow" or
# "none":
#
#   AN EMPTY COMPANY MEANS EVERY COMPANY. A System-scope assignment carries company = "", so a
#   blank cell turns the broadest grant in the finance system into the one that looks like
#   nothing. Measured on one tenant: 157 enabled SUPER assignments, most of them company-blank.
#
#   A DISABLED USER STILL HOLDS ASSIGNMENTS. Dropping them silently hides an account that need
#   only be re-enabled; counting them as live overstates exposure. They are excluded by default
#   AND the number hidden is reported.
#
#   AN ENVIRONMENT THAT COULD NOT BE READ IS NOT AN EMPTY ONE. A failed enumeration must warn
#   and name the environment, or an unreviewed sandbox reads as a clean one.
#
#   userPermissionSets RETURNS HTTP 400 ON SOME ENVIRONMENTS and data on others within the same
#   major version, so accessControls is used instead. A test pins that it is never called.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecBusinessCentralAccess' {
    BeforeEach {
        InModuleScope msec {
            Mock Get-MsecBusinessCentralToken -MockWith {
                [pscustomobject]@{ Resource = 'https://api.businesscentral.dynamics.com'
                                   Headers  = @{ Authorization = 'Bearer x' } }
            }
        }
    }

    It 'renders a blank company as every company, not as nothing' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production' }) }
                }
                elseif ($Uri -match '/api/v2\.0/companies$') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1'; name = 'Co' }) }
                }
                elseif ($Uri -match 'usersPermissions') {
                    [pscustomobject]@{ value = @([pscustomobject]@{
                        userSecurityId = 'u1'; state = 'Enabled'; licenseType = 'Full User'
                        authenticationEmail = 'a@contoso.com'; expiryDate = '0001-01-01T00:00:00Z'
                        applicationId = '00000000-0000-0000-0000-000000000000' }) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ userSecurityId = 'u1'; roleId = 'SUPER'; roleName = 'all'
                                           company = ''; userName = 'A'; scope = 'System'
                                           userLicenseType = 'Full User'; appName = '' }
                        [pscustomobject]@{ userSecurityId = 'u1'; roleId = 'D365 BASIC'; roleName = 'basic'
                                           company = 'Contoso Inc.'; userName = 'A'; scope = 'Tenant'
                                           userLicenseType = 'Full User'; appName = '' }
                    ) }
                }
            }
            @(Get-MsecBusinessCentralAccess -WarningAction SilentlyContinue)
        }

        ($rows | Where-Object RoleId -eq 'SUPER').Company      | Should -Be '(all companies)'
        ($rows | Where-Object RoleId -eq 'D365 BASIC').Company | Should -Be 'Contoso Inc.'
        # 0001-01-01 is the product's "never expires", not a date in the past. Comparing against
        # DateTime::MinValue does NOT catch it - parsing the Z-suffixed sentinel converts to
        # local time, so east of UTC it lands just above MinValue and reads as a real date.
        ($rows | Where-Object RoleId -eq 'SUPER').ExpiryDate   | Should -BeNullOrEmpty
    }

    It 'excludes disabled users by default but reports how many were hidden' {
        $r = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production' }) } }
                elseif ($Uri -match '/api/v2\.0/companies$') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1' }) } }
                elseif ($Uri -match 'usersPermissions') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ userSecurityId = 'live'; state = 'Enabled';  applicationId = '00000000-0000-0000-0000-000000000000' }
                        [pscustomobject]@{ userSecurityId = 'dead'; state = 'Disabled'; applicationId = '00000000-0000-0000-0000-000000000000' }
                    ) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ userSecurityId = 'live'; roleId = 'SUPER'; company = ''; userName = 'LIVE' }
                        [pscustomobject]@{ userSecurityId = 'dead'; roleId = 'SUPER'; company = ''; userName = 'DEAD' }
                    ) }
                }
            }
            $rows = @(Get-MsecBusinessCentralAccess -WarningVariable wv -WarningAction SilentlyContinue)
            $withDisabled = @(Get-MsecBusinessCentralAccess -IncludeDisabled -WarningAction SilentlyContinue)
            [pscustomobject]@{ Default = $rows; All = $withDisabled; Warnings = $wv }
        }

        @($r.Default).Count | Should -Be 1
        $r.Default.UserName | Should -Be 'LIVE'
        @($r.All).Count     | Should -Be 2
        # Silently dropping them would hide an account that re-enabling restores.
        ($r.Warnings | Where-Object { "$_" -match '1 assignment' }) | Should -Not -BeNullOrEmpty
    }

    It 'marks an Entra application principal, which Entra alone cannot characterise' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production' }) } }
                elseif ($Uri -match '/api/v2\.0/companies$') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1' }) } }
                elseif ($Uri -match 'usersPermissions') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ userSecurityId = 'app'; state = 'Enabled'; applicationId = '11111111-1111-1111-1111-111111111111' }
                        [pscustomobject]@{ userSecurityId = 'guy'; state = 'Enabled'; applicationId = '00000000-0000-0000-0000-000000000000' }
                    ) }
                }
                else {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ userSecurityId = 'app'; roleId = 'SUPER'; company = ''; userName = 'MSOLSYNC' }
                        [pscustomobject]@{ userSecurityId = 'guy'; roleId = 'SUPER'; company = ''; userName = 'PERSON' }
                    ) }
                }
            }
            @(Get-MsecBusinessCentralAccess -ApplicationsOnly -WarningAction SilentlyContinue)
        }

        @($rows).Count | Should -Be 1
        $rows.UserName      | Should -Be 'MSOLSYNC'
        $rows.IsApplication | Should -BeTrue
        # The all-zero GUID is "not an application", not an application with a null id.
        $rows.ApplicationId | Should -Be '11111111-1111-1111-1111-111111111111'
    }

    It 'warns and skips an environment whose access could not be read, rather than returning it empty' {
        $r = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ name = 'Good'; type = 'Production' }
                        [pscustomobject]@{ name = 'Bad';  type = 'Sandbox' }) }
                }
                elseif ($Uri -match '/Bad/') { throw 'boom' }
                elseif ($Uri -match '/api/v2\.0/companies$') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1' }) } }
                elseif ($Uri -match 'usersPermissions') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ userSecurityId = 'u'; state = 'Enabled'; applicationId = '00000000-0000-0000-0000-000000000000' }) }
                }
                else { [pscustomobject]@{ value = @([pscustomobject]@{ userSecurityId = 'u'; roleId = 'SUPER'; company = ''; userName = 'A' }) } }
            }
            $rows = @(Get-MsecBusinessCentralAccess -WarningVariable wv -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = $wv }
        }

        @($r.Rows).Count | Should -Be 1
        # An unreviewed environment must be named, or it reads as a clean one.
        ($r.Warnings | Where-Object { "$_" -match "'Bad'" -and "$_" -match 'NOT included' }) | Should -Not -BeNullOrEmpty
    }

    It 'never calls userPermissionSets, which 400s on some environments and works on others' {
        $uris = InModuleScope msec {
            $script:Uris = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-RestMethod -MockWith {
                $script:Uris.Add([string]$Uri)
                if ($Uri -match '/environments$') { [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production' }) } }
                elseif ($Uri -match '/api/v2\.0/companies$') { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1' }) } }
                elseif ($Uri -match 'usersPermissions') { [pscustomobject]@{ value = @() } }
                else { [pscustomobject]@{ value = @() } }
            }
            Get-MsecBusinessCentralAccess -WarningAction SilentlyContinue | Out-Null
            $script:Uris
        }

        ($uris -join ' ') | Should -Not -Match 'userPermissionSets'
        ($uris -join ' ') | Should -Match 'accessControls'
    }

    It 'names the environments that exist when an unknown one is asked for' {
        $w = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production' }) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            Get-MsecBusinessCentralAccess -Environment 'NoSuchEnv' -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            $wv
        }
        ($w | Where-Object { "$_" -match 'NoSuchEnv' -and "$_" -match 'Prod' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-MsecBusinessCentralEnvironment' {
    BeforeEach {
        InModuleScope msec {
            Mock Get-MsecBusinessCentralToken -MockWith {
                [pscustomobject]@{ Resource = 'https://api.businesscentral.dynamics.com'; Headers = @{} }
            }
        }
    }

    It 'leaves a count null when it could not be taken, rather than reporting zero' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                if ($Uri -match '/environments$') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ name = 'Prod'; type = 'Production'; countryCode = 'SE' }) }
                }
                else { throw 'denied' }
            }
            @(Get-MsecBusinessCentralEnvironment)
        }

        # An environment that refused enumeration must not render as an empty one - that is the
        # reading which turns an unreviewed sandbox into a harmless-looking row.
        $rows.Companies | Should -BeNullOrEmpty
        $rows.Users     | Should -BeNullOrEmpty
        $rows.Name      | Should -Be 'Prod'
    }

    It 'filters to non-production with -SandboxOnly' {
        $rows = InModuleScope msec {
            Mock Invoke-RestMethod -MockWith {
                [pscustomobject]@{ value = @(
                    [pscustomobject]@{ name = 'Prod'; type = 'Production' }
                    [pscustomobject]@{ name = 'Box';  type = 'Sandbox' }) }
            }
            @(Get-MsecBusinessCentralEnvironment -SandboxOnly -Quick)
        }
        @($rows).Count | Should -Be 1
        $rows.Name     | Should -Be 'Box'
    }
}
