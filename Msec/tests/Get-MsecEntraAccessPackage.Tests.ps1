#Requires -Module Pester
#
# Tests for Get-MsecEntraAccessPackage.
#
# The traps here are all about a control reading as present when it is absent, or absent when
# it is simply unconfigurable:
#
#   APPROVAL AND EXPIRY ARE DIFFERENT CONTROLS. Approval governs who gets in, expiry governs how
#   long they stay. Measured on one tenant: all 77 policies required approval and 69 never
#   expired, including 25 packages granting directory administrator roles. Reading the approval
#   column alone calls that fully governed.
#
#   noExpiration MUST RENDER AS 'never', NOT BLANK. An empty expiry cell reads as "not
#   configured yet" and invites assuming a default applies. It IS the configuration.
#
#   A PACKAGE WITH NO POLICY HAS ApprovalRequired $null, NOT $false. "Nobody can request this"
#   and "anyone gets it unapproved" are opposite findings and must not share a rendering.
#
#   THE NESTED EXPAND IS LOAD-BEARING. With $expand=role,scope the scope is named "Root" on
#   every package, because the scope is the extent within the resource rather than the resource.
#   Only role($expand=resource) names the group the package actually grants.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop
}
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecEntraAccessPackage' {
    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{
                TenantId = 't'; ClientId = 'c'; KeyVaultName = 'kv'; KeyName = 'k'
                ThumbprintBytes = [byte[]](1..20); Tokens = @{}
            }
        }
    }

    It 'renders noExpiration as never, and a real duration as itself' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -match 'accessPackages\?') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'Admin Access'; isHidden = $false
                        catalog = [pscustomobject]@{ displayName = 'Privileged' } }) }
                }
                elseif ($Path -match 'assignmentPolicies') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'pol1'; displayName = 'forever'; allowedTargetScope = 'specificDirectoryUsers'
                            expiration = [pscustomobject]@{ type = 'noExpiration' }
                            requestApprovalSettings = [pscustomobject]@{ isApprovalRequiredForAdd = $true }
                            accessPackage = [pscustomobject]@{ id = 'p1' } }
                        [pscustomobject]@{ id = 'pol2'; displayName = 'a year'; allowedTargetScope = 'allMemberUsers'
                            expiration = [pscustomobject]@{ type = 'afterDuration'; duration = 'P365D' }
                            requestApprovalSettings = [pscustomobject]@{ isApprovalRequiredForAdd = $true }
                            accessPackage = [pscustomobject]@{ id = 'p1' } }
                    ) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            @(Get-MsecEntraAccessPackage -WarningAction SilentlyContinue)
        }

        @($rows).Count | Should -Be 2
        ($rows | Where-Object Policy -eq 'forever').Expiration | Should -Be 'never'
        ($rows | Where-Object Policy -eq 'a year').Expiration  | Should -Be 'P365D'
        # Blank would read as "not configured yet" and invite assuming a default applies.
        ($rows | Where-Object Policy -eq 'forever').Expiration | Should -Not -BeNullOrEmpty
    }

    It 'leaves ApprovalRequired null for a package with no policy, not false' {
        $row = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -match 'accessPackages\?') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'orphan'; displayName = 'No policy yet'
                        catalog = [pscustomobject]@{ displayName = 'General' } }) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            Get-MsecEntraAccessPackage -WarningAction SilentlyContinue
        }

        # The package still appears - it exists and could be given a policy tomorrow.
        $row.Package | Should -Be 'No policy yet'
        # $null, NOT $false: nobody can request it, which is the opposite of "no approval needed".
        $row.ApprovalRequired  | Should -BeNullOrEmpty
        $row.ApprovalRequired  | Should -Not -Be $false
        $row.Policy            | Should -BeNullOrEmpty
        $row.AllowedTargetScope | Should -BeNullOrEmpty
    }

    It 'names the granted resource via the nested expand, not the "Root" scope' {
        $captured = InModuleScope msec {
            $script:Paths = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-MsecGraphRequest -MockWith {
                $script:Paths.Add([string]$Path)
                if ($Path -match 'accessPackages\?') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'Auth Admin'
                        catalog = [pscustomobject]@{ displayName = 'Privileged' } }) }
                }
                elseif ($Path -match 'assignmentPolicies') { [pscustomobject]@{ value = @() } }
                elseif ($Path -match 'resourceRoleScopes') {
                    [pscustomobject]@{ value = @([pscustomobject]@{
                        role = [pscustomobject]@{ displayName = 'Member'; originSystem = 'AadGroup'
                                                  resource = [pscustomobject]@{ displayName = 'pim-entra-authentication-administrator' } }
                        scope = [pscustomobject]@{ displayName = 'Root' } }) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            $r = Get-MsecEntraAccessPackage -WarningAction SilentlyContinue
            [pscustomobject]@{ Row = $r; Paths = $script:Paths }
        }

        # The resource, not the scope. "Root/Member" names nothing and is the same on every package.
        $captured.Row.ResourceRole | Should -Contain 'pim-entra-authentication-administrator/Member [AadGroup]'
        ($captured.Paths -join ' ') | Should -Match 'expand=role\(\$expand=resource\)'
        # string[], so -contains tests it exactly rather than -like '*Administrator*'.
        $captured.Row.ResourceRole -is [array] | Should -BeTrue
    }

    It 'filters on expiry, approval and self-requestability independently' {
        $sets = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -match 'accessPackages\?') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'Pkg'
                        catalog = [pscustomobject]@{ displayName = 'Cat' } }) }
                }
                elseif ($Path -match 'assignmentPolicies') {
                    [pscustomobject]@{ value = @(
                        [pscustomobject]@{ id = 'a'; displayName = 'named-approved-never'; allowedTargetScope = 'specificDirectoryUsers'
                            expiration = [pscustomobject]@{ type = 'noExpiration' }
                            requestApprovalSettings = [pscustomobject]@{ isApprovalRequiredForAdd = $true }
                            accessPackage = [pscustomobject]@{ id = 'p1' } }
                        [pscustomobject]@{ id = 'b'; displayName = 'open-unapproved-never'; allowedTargetScope = 'allMemberUsers'
                            expiration = [pscustomobject]@{ type = 'noExpiration' }
                            requestApprovalSettings = [pscustomobject]@{ isApprovalRequiredForAdd = $false }
                            accessPackage = [pscustomobject]@{ id = 'p1' } }
                        [pscustomobject]@{ id = 'c'; displayName = 'named-approved-90d'; allowedTargetScope = 'specificDirectoryUsers'
                            expiration = [pscustomobject]@{ type = 'afterDuration'; duration = 'P90D' }
                            requestApprovalSettings = [pscustomobject]@{ isApprovalRequiredForAdd = $true }
                            accessPackage = [pscustomobject]@{ id = 'p1' } }
                    ) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            [pscustomobject]@{
                All        = @(Get-MsecEntraAccessPackage -WarningAction SilentlyContinue)
                NoExpiry   = @(Get-MsecEntraAccessPackage -NoExpiry -WarningAction SilentlyContinue)
                NoApproval = @(Get-MsecEntraAccessPackage -NoApproval -WarningAction SilentlyContinue)
                SelfReq    = @(Get-MsecEntraAccessPackage -SelfRequestable -WarningAction SilentlyContinue)
            }
        }

        $sets.All.Count        | Should -Be 3
        $sets.NoExpiry.Count   | Should -Be 2
        $sets.NoApproval.Count | Should -Be 1
        $sets.NoApproval.Policy | Should -Be 'open-unapproved-never'
        $sets.SelfReq.Count    | Should -Be 1
        $sets.SelfReq.Policy   | Should -Be 'open-unapproved-never'
    }

    It 'names the catalogs that exist when an unknown one is asked for' {
        $w = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -match 'accessPackages\?') {
                    [pscustomobject]@{ value = @([pscustomobject]@{ id = 'p1'; displayName = 'Pkg'
                        catalog = [pscustomobject]@{ displayName = 'Privileged' } }) }
                }
                else { [pscustomobject]@{ value = @() } }
            }
            Get-MsecEntraAccessPackage -Catalog 'Nope' -WarningVariable wv -WarningAction SilentlyContinue | Out-Null
            $wv
        }
        ($w | Where-Object { "$_" -match "'Nope'" -and "$_" -match 'Privileged' }) | Should -Not -BeNullOrEmpty
    }

    It 'rewrites a 403 to name the permission' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw '403 Forbidden' }
            { Get-MsecEntraAccessPackage } | Should -Throw '*EntitlementManagement.Read.All*'
        }
    }
}
