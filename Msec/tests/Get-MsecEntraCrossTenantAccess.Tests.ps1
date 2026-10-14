BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psd1') -Force

    # Defined here rather than in the Describe body: a variable set at discovery time is gone
    # by the time an It runs, which reads as the command returning nothing.
    #
    # The default TRUSTS MFA and the partners mostly do not override it - which is the shape
    # that exposes the inherit-vs-false defect. p-explicit opts out deliberately.
    $script:Default = @{
        inboundTrust = @{
            isMfaAccepted = $true
            isCompliantDeviceAccepted = $false
            isHybridAzureADJoinedDeviceAccepted = $false
        }
        b2bCollaborationInbound  = @{ usersAndGroups = @{ accessType = 'allowed' } }
        b2bCollaborationOutbound = @{ usersAndGroups = @{ accessType = 'allowed' } }
    }

    $script:Partners = @(
        # No inboundTrust at all - Graph returns null, meaning INHERIT.
        @{ tenantId = 'p-inherit' }

        # Explicitly opts out of the default's MFA trust.
        @{ tenantId = 'p-explicit'
           inboundTrust = @{ isMfaAccepted = $false
                             isCompliantDeviceAccepted = $false
                             isHybridAzureADJoinedDeviceAccepted = $false }
           b2bCollaborationInbound = @{ usersAndGroups = @{ accessType = 'blocked' } } }
    )
}

Describe 'Get-MsecEntraCrossTenantAccess' {

    BeforeEach {
        InModuleScope msec { Mock Assert-MsecSession {} }
    }

    It 'resolves an inherited setting to the default rather than reporting false' {
        # THE DEFECT THE COMMAND EXISTS TO PREVENT. Graph returns inboundTrust as null on a
        # partner with no override; null renders as blank or False in any table, so a tenant
        # whose default trusts MFA would be reported as trusting nothing.
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            $row = Get-MsecEntraCrossTenantAccess | Where-Object TenantId -eq 'p-inherit'
            $row.TrustsMfa   | Should -BeTrue
            $row.IsInherited | Should -BeTrue
        }
    }

    It 'keeps an explicit false even when the default is true' {
        # The opposite error: resolving everything to the default would erase a deliberate
        # opt-out, which is a real decision someone made about a specific partner.
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            $row = Get-MsecEntraCrossTenantAccess | Where-Object TenantId -eq 'p-explicit'
            $row.TrustsMfa   | Should -BeFalse
            $row.IsInherited | Should -BeFalse
        }
    }

    It 'returns the default as a row of its own' {
        # The partners list describes the organisations someone once configured. The default
        # governs everyone else - on a measured tenant that was every CRO with actual guests.
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            $rows = Get-MsecEntraCrossTenantAccess
            $rows[0].Scope       | Should -Be 'Default'
            $rows[0].TrustsMfa   | Should -BeTrue
            $rows[0].IsInherited | Should -BeFalse
            @($rows).Count       | Should -Be 3
        }
    }

    It 'treats a missing accessType as allowed, not as unknown' {
        # An entry that was never narrowed has no accessType. Blank would read as 'unknown'
        # for what is in fact the ordinary B2B default.
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') {
                    return @{ inboundTrust = @{ isMfaAccepted = $false } }
                }
                if ($Path -like '*partners*') { return @(@{ tenantId = 'p1' }) }
                return @{ displayName = 'X' }
            }
            (Get-MsecEntraCrossTenantAccess).InboundB2B | Should -Not -Contain ''
            (Get-MsecEntraCrossTenantAccess)[0].InboundB2B | Should -Be 'allowed'
        }
    }

    It '-BlockedOnly returns the partners barred from collaborating' {
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            (Get-MsecEntraCrossTenantAccess -BlockedOnly).TenantId | Should -Be @('p-explicit')
        }
    }

    It '-TrustingMfaOnly uses the effective value, so it includes inheritors' {
        # An inheriting partner DOES trust MFA when the default does. Filtering on the raw
        # field would silently omit exactly the rows that matter.
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            $t = Get-MsecEntraCrossTenantAccess -TrustingMfaOnly
            $t.TenantId | Should -Contain 'p-inherit'
            $t.TenantId | Should -Not -Contain 'p-explicit'
        }
    }

    It 'reports the tenant id when the name cannot be resolved' {
        # An unnamed partner is still a partner; a blank would read as no partner at all.
        InModuleScope msec -Parameters @{ D = $script:Default } {
            param($D)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return @(@{ tenantId = 'unknown-tenant' }) }
                throw 'tenant not found'
            }
            $row = Get-MsecEntraCrossTenantAccess | Where-Object Scope -eq 'Partner'
            $row.TenantName | Should -Be 'unknown-tenant'
        }
    }

    It 'resolves each tenant name once' {
        InModuleScope msec -Parameters @{ D = $script:Default } {
            param($D)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return @(@{ tenantId = 'dup' }, @{ tenantId = 'dup' }) }
                return @{ displayName = 'Dup Inc' }
            }
            Get-MsecEntraCrossTenantAccess | Out-Null
            Should -Invoke Invoke-MsecGraphRequest -Times 1 -Exactly -ParameterFilter {
                $Path -like "*findTenantInformationByTenantId(tenantId='dup')*"
            }
        }
    }

    It 'names the missing permission when Graph refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraCrossTenantAccess } | Should -Throw '*Policy.Read.All*'
        }
    }

    It 'emits the documented type so the table view applies' {
        InModuleScope msec -Parameters @{ D = $script:Default; P = $script:Partners } {
            param($D, $P)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*crossTenantAccessPolicy/default*') { return $D }
                if ($Path -like '*partners*') { return $P }
                return @{ displayName = 'Partner Inc' }
            }
            (Get-MsecEntraCrossTenantAccess)[0].PSObject.TypeNames |
                Should -Contain 'MsecEntraCrossTenantAccess'
        }
    }
}
