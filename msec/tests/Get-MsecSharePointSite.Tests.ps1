#Requires -Module Pester
#
# Tests for Get-MsecSharePointSite, and specifically for -IncludeSettings.
#
# The traps:
#
#   TWO SHARING SETTINGS DECIDE AN EXTERNAL SHARE AND NEITHER IS READABLE HERE. A site's own
#   sharing level and its own domain allow-list live on the tenant-admin surface, behind
#   Sites.FullControl.All - a WRITE permission this module does not hold. -IncludeSettings must
#   never look like it covers them.
#
#   "COULD NOT READ" MUST NOT LOOK LIKE "ALL OFF". Settings is $null on failure, never a blank
#   object whose every flag reads as False.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # DISCOVERABLE IS NOT USABLE. Pester's Mock needs the command to exist AND to yield
    # CommandMetadata; PnP.PowerShell is not a dependency of msec, so on a runner without it
    # the mock fails to build and the test reads as a bug in the code.
    $script:StubbedPnP = @()
    $usable = $false
    $found  = Get-Command Get-PnPTenantSite -ErrorAction SilentlyContinue
    if ($found) {
        try   { $null = [System.Management.Automation.CommandMetadata]::new($found); $usable = $true }
        catch { $usable = $false }
    }
    if (-not $usable) {
        Set-Item 'function:global:Get-PnPTenantSite' -Value { [CmdletBinding()] param([string] $Identity) } -Force
        $script:StubbedPnP += 'Get-PnPTenantSite'
    }
}
AfterAll {
    foreach ($c in $script:StubbedPnP) { Remove-Item "function:$c" -ErrorAction SilentlyContinue }
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecSharePointSite -CreatedSince' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ displayName='Old'; name='old'; webUrl='https://contoso.sharepoint.com/sites/old'
                                       id='contoso.sharepoint.com,1,1'; createdDateTime='2020-01-01T00:00:00Z'
                                       siteCollection=[pscustomobject]@{ hostname='contoso.sharepoint.com' } },
                    [pscustomobject]@{ displayName='New'; name='new'; webUrl='https://contoso.sharepoint.com/sites/new'
                                       id='contoso.sharepoint.com,2,2'; createdDateTime='2026-09-25T00:00:00Z'
                                       siteCollection=[pscustomobject]@{ hostname='contoso.sharepoint.com' } },
                    [pscustomobject]@{ displayName='Undated'; name='undated'; webUrl='https://contoso.sharepoint.com/sites/undated'
                                       id='contoso.sharepoint.com,3,3'; createdDateTime=$null
                                       siteCollection=[pscustomobject]@{ hostname='contoso.sharepoint.com' } }
                )
            }
        }
    }

    It 'returns only sites created on or after the date' {
        $r = InModuleScope msec { Get-MsecSharePointSite -CreatedSince ([datetime]'2026-01-01') -WarningAction SilentlyContinue }
        @($r).DisplayName | Should -Contain 'New'
        @($r).DisplayName | Should -Not -Contain 'Old'
    }

    It 'includes a site with no creation date rather than dropping it' {
        # ABSENT IS NOT OLD. A site nobody can date is exactly the one worth looking at, so a
        # date filter must not silently remove it from a review worklist.
        $r = InModuleScope msec { Get-MsecSharePointSite -CreatedSince ([datetime]'2026-01-01') -WarningAction SilentlyContinue }
        @($r).DisplayName | Should -Contain 'Undated'
    }

    It 'warns about the undated site, so its inclusion is not silent' {
        $w = InModuleScope msec {
            $null = Get-MsecSharePointSite -CreatedSince ([datetime]'2026-01-01') -WarningVariable wv -WarningAction SilentlyContinue
            ($wv -join ' ')
        }
        $w | Should -BeLike '*undated*'
    }

    It 'filters nothing when the parameter is omitted' {
        $r = InModuleScope msec { Get-MsecSharePointSite }
        @($r).Count | Should -Be 3
    }
}

Describe 'Get-MsecSharePointSite -IncludeSettings' {

    BeforeEach {
        InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                @([pscustomobject]@{
                    displayName = 'Contoso Translations'; name = 'ContosoTranslations'
                    webUrl = 'https://contoso.sharepoint.com/sites/ContosoTranslations'
                    id = 'contoso.sharepoint.com,11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222'
                    createdDateTime = '2025-01-27T15:16:23Z'; lastModifiedDateTime = '2026-06-04T17:13:39Z'
                    siteCollection = [pscustomobject]@{ hostname = 'contoso.sharepoint.com' }
                })
            }
            Mock Get-MsecAccessToken -MockWith { 'token' }
        }
    }

    It 'does not call the site API unless asked' {
        # One request per site; on a large tenant that is the difference between seconds and
        # minutes, so it stays opt-in.
        InModuleScope msec {
            Mock Invoke-MsecRetryableRequest -MockWith { @{} }
            $null = Get-MsecSharePointSite
            Should -Invoke Invoke-MsecRetryableRequest -Times 0
        }
    }

    It 'projects the site settings when asked' {
        $r = InModuleScope msec {
            Mock Invoke-MsecRetryableRequest -MockWith {
                @{ ShareByEmailEnabled = $true; ShareByLinkEnabled = $false
                   DisableCompanyWideSharingLinks = $false; ExternalSharingTipsEnabled = $true
                   IsRestrictedAccessControlPolicyEnforcedOnSite = $false
                   SensitivityLabelId = '00000000-0000-0000-0000-000000000000'
                   GroupId = '00000000-0000-0000-0000-000000000000'; ReadOnly = $false }
            }
            Get-MsecSharePointSite -IncludeSettings
        }

        $r.Settings                     | Should -Not -BeNullOrEmpty
        $r.Settings.ShareByEmailEnabled | Should -BeTrue
        $r.Settings.ShareByLinkEnabled  | Should -BeFalse
        # All-zero GUIDs are "not set", not a value worth reporting.
        $r.Settings.SensitivityLabelId  | Should -BeNullOrEmpty
        $r.Settings.GroupId             | Should -BeNullOrEmpty
    }

    It 'leaves Settings $null when the site could not be read, never a blank object' {
        # THE BUG THIS PREVENTS. A blank object reads as "every sharing flag is off", which is
        # a confident wrong answer about a site nobody could actually query.
        $r = InModuleScope msec {
            Mock Invoke-MsecRetryableRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            Get-MsecSharePointSite -IncludeSettings -WarningAction SilentlyContinue
        }

        $r.Settings | Should -BeNullOrEmpty
        $r.WebUrl   | Should -Be 'https://contoso.sharepoint.com/sites/ContosoTranslations'
    }

    It 'warns when a site could not be read, so a gap is not silent' {
        $w = InModuleScope msec {
            Mock Invoke-MsecRetryableRequest -MockWith { throw 'boom' }
            $null = Get-MsecSharePointSite -IncludeSettings -WarningVariable wv -WarningAction SilentlyContinue
            ($wv -join ' ')
        }

        $w | Should -BeLike '*ContosoTranslations*'
    }

    It 'never claims to carry the sharing level or the domain list' {
        # Those need Sites.FullControl.All - a write permission msec will not hold - so no
        # property here may be named as though it answered them.
        $names = InModuleScope msec {
            Mock Invoke-MsecRetryableRequest -MockWith {
                @{ ShareByEmailEnabled = $true; SharingCapability = 'ExternalUserSharingOnly'
                   SharingAllowedDomainList = 'contoso.com' }
            }
            @((Get-MsecSharePointSite -IncludeSettings).Settings.PSObject.Properties.Name)
        }

        $names | Should -Not -Contain 'SharingCapability'
        $names | Should -Not -Contain 'SharingAllowedDomainList'
        $names | Should -Contain 'ShareByEmailEnabled'
    }
}
