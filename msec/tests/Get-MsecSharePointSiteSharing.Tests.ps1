#Requires -Module Pester
#
# Tests for Get-MsecSharePointSiteSharing.
#
# The traps:
#
#   THE BULK CALL LIES ABOUT THE DOMAIN RESTRICTION. Get-PnPTenantSite with no -Identity
#   reports SharingDomainRestrictionMode "None" and an empty list for a site that has one.
#   Measured: bulk said None, -Identity said AllowList with four domains.
#
#   "COULD NOT READ" MUST NOT BECOME "None", which is the one value that would be believed.
#
#   THE APP CANNOT DO THIS AT ALL, so the error has to name the interactive sign-in rather
#   than sending the reader to check app permissions.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psm1') -Force -ErrorAction Stop

    # DISCOVERABLE IS NOT USABLE - PnP is not a dependency of msec, so on a runner without it
    # Pester's Mock cannot build and the test reads as a bug in the code.
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

Describe 'Get-MsecSharePointSiteSharing' {

    BeforeEach {
        InModuleScope msec {
            Mock Get-PnPTenantSite -ParameterFilter { $Identity } -MockWith {
                [pscustomobject]@{ Url=$Identity; Title='Translations'; Template='SITEPAGEPUBLISHING#0'
                                   SharingCapability='ExternalUserSharingOnly'
                                   SharingDomainRestrictionMode='AllowList'
                                   SharingAllowedDomainList='CONTOSO.COM,FABRIKAM.COM'
                                   SharingBlockedDomainList='' }
            }
            # The bulk call: correct level, WRONG restriction.
            Mock Get-PnPTenantSite -MockWith {
                @(
                    [pscustomobject]@{ Url='https://contoso.sharepoint.com/sites/Translations'; Title='Translations'
                                       Template='SITEPAGEPUBLISHING#0'; SharingCapability='ExternalUserSharingOnly'
                                       SharingDomainRestrictionMode='None'; SharingAllowedDomainList=''
                                       SharingBlockedDomainList='' },
                    [pscustomobject]@{ Url='https://contoso.sharepoint.com/sites/Open'; Title='Open'
                                       Template='STS#3'; SharingCapability='ExternalUserAndGuestSharing'
                                       SharingDomainRestrictionMode='None'; SharingAllowedDomainList=''
                                       SharingBlockedDomainList='' }
                )
            }
        }
    }

    It 'returns the sharing level from one bulk call' {
        $r = InModuleScope msec { Get-MsecSharePointSiteSharing }
        @($r).Count | Should -Be 2
        ($r | Where-Object Title -eq 'Translations').SharingLevel | Should -Be 'ExternalUserSharingOnly'
    }

    It 'does NOT report a domain restriction unless asked, because the bulk value is wrong' {
        # THE BUG THIS PREVENTS. Reporting the bulk value would say no site restricts by
        # domain - measured false on the very site used here.
        $r = InModuleScope msec { Get-MsecSharePointSiteSharing }
        ($r | Where-Object Title -eq 'Translations').DomainRestriction | Should -BeNullOrEmpty
        ($r | Where-Object Title -eq 'Translations').AllowedDomains    | Should -BeNullOrEmpty
    }

    It 'queries per site for the domain restriction, and gets the truth' {
        $r = InModuleScope msec { Get-MsecSharePointSiteSharing -IncludeDomainRestriction }
        $t = $r | Where-Object Title -eq 'Translations'
        $t.DomainRestriction | Should -Be 'AllowList'
        $t.AllowedDomains    | Should -Contain 'CONTOSO.COM'
        $t.AllowedDomains    | Should -Contain 'FABRIKAM.COM'
    }

    It 'leaves DomainRestriction $null when a site could not be read, never None' {
        # "None" is the one wrong value that would be believed, so a failed read must not
        # produce it.
        $r = InModuleScope msec {
            Mock Get-PnPTenantSite -ParameterFilter { $Identity } -MockWith { throw 'boom' }
            Get-MsecSharePointSiteSharing -IncludeDomainRestriction -WarningAction SilentlyContinue
        }
        @($r)[0].DomainRestriction | Should -BeNullOrEmpty
    }

    It 'needs no second call when a single site was requested' {
        # A single-site query already carries the domain fields.
        InModuleScope msec {
            $null = Get-MsecSharePointSiteSharing -Url 'https://contoso.sharepoint.com/sites/Translations' -IncludeDomainRestriction
            Should -Invoke Get-PnPTenantSite -Times 1 -Exactly -ParameterFilter { $Identity }
        }
    }

    It 'names the interactive sign-in when the admin API refuses' {
        $msg = InModuleScope msec {
            Mock Get-PnPTenantSite -MockWith { throw 'Attempted to perform an unauthorized operation.' }
            try { Get-MsecSharePointSiteSharing | Out-Null } catch { $_.Exception.Message }
        }
        $msg | Should -BeLike '*-Interactive*'
        $msg | Should -BeLike '*Sites.FullControl.All*'
    }

    It 'RestrictedOnly drops the wide-open sites and keeps everything else' {
        $r = InModuleScope msec { Get-MsecSharePointSiteSharing -RestrictedOnly }
        @($r).Title | Should -Contain 'Translations'
        @($r).Title | Should -Not -Contain 'Open'
    }
}
