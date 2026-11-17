BeforeAll {
    Import-Module "$PSScriptRoot/../msec.psd1" -Force
}

# NB: -like treats '?' as a SINGLE-CHARACTER WILDCARD, so a pattern like '*servicePrincipals?*'
# matches '/servicePrincipals/sp1/appRoleAssignedTo' as well as the collection URL - every mock
# branch then answers every call and the command silently returns nothing. The routing below is
# ordered most-specific-first and contains no '?' for that reason.
Describe 'Get-MsecEntraAppAssignment' {

    It 'keeps User and Group principals, and leaves ServicePrincipal to Get-MsecEntraAppConsent' {
        # The two commands split the same Graph collection. A ServicePrincipal row here would
        # be an application permission granted to software - a different question, and counting
        # it as a person inflates an access review.
        $rows = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*') {
                    return @(
                        [pscustomobject]@{ id='a1'; principalType='User';             principalId='u1'; principalDisplayName='Ann';   appRoleId='r1'; createdDateTime='2024-01-01' }
                        [pscustomobject]@{ id='a2'; principalType='Group';            principalId='g1'; principalDisplayName='Team';  appRoleId='r1'; createdDateTime='2024-01-02' }
                        [pscustomobject]@{ id='a3'; principalType='ServicePrincipal'; principalId='s1'; principalDisplayName='Robot'; appRoleId='r1'; createdDateTime='2024-01-03' }
                    )
                }
                if ($Path -like '*/users/*')               { return [pscustomobject]@{ userPrincipalName = 'ann@contoso.com'; accountEnabled = $true } }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @([pscustomobject]@{ id = 'r1'; displayName = 'Operator' }) } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }
            @(Get-MsecEntraAppAssignment -DisplayName 'app-one')
        }

        @($rows).Count | Should -Be 2
        $rows.PrincipalType | Should -Not -Contain 'ServicePrincipal'
        ($rows | Where-Object PrincipalType -eq 'User').UserPrincipalName | Should -Be 'ann@contoso.com'
        ($rows | Where-Object PrincipalType -eq 'User').Role              | Should -Be 'Operator'
    }

    It 'leaves UserPrincipalName null for a group rather than inventing one' {
        # $null here means "not applicable", and it must stay distinguishable from a failed
        # user read, which reports 'Unreadable'.
        $group = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*') {
                    return @([pscustomobject]@{ id='a2'; principalType='Group'; principalId='g1'; principalDisplayName='Team'; appRoleId='00000000-0000-0000-0000-000000000000'; createdDateTime='2024-01-02' })
                }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @() } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }
            @(Get-MsecEntraAppAssignment -DisplayName 'app-one')
        }

        $null -eq $group[0].UserPrincipalName | Should -BeTrue
        $null -eq $group[0].UserEnabled       | Should -BeTrue
        # The all-zero appRoleId is the portal's "Default Access", not a missing role.
        $group[0].Role | Should -Be 'Default Access'
    }

    It "reports a failed user read as 'Unreadable' instead of as a group-shaped null" {
        # REGRESSION: a 403 on /users/{id} must not render the same as a Group's legitimately
        # null UPN. Collapsing the two makes a partly-unreadable review look complete.
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*') {
                    return @([pscustomobject]@{ id='a1'; principalType='User'; principalId='u1'; principalDisplayName='Ann'; appRoleId='r1'; createdDateTime='2024-01-01' })
                }
                if ($Path -like '*/users/*')               { throw 'Forbidden' }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @([pscustomobject]@{ id='r1'; displayName='Operator' }) } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }
            @(Get-MsecEntraAppAssignment -DisplayName 'app-one' -WarningAction SilentlyContinue)
        }

        $result[0].UserPrincipalName | Should -Be 'Unreadable'
        $null -eq $result[0].UserEnabled | Should -BeTrue
    }

    It 'warns when a -DisplayName pattern matches nothing, so it cannot read as "nobody has access"' {
        # REGRESSION: a renamed app, or a wildcard that misses, returns an empty result
        # identical to an app with no assignments. On a monthly review that is the dangerous
        # direction to be wrong in - a live tenant had a fifth app carrying an extra suffix that the
        # obvious wildcard excluded.
        $warnings = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*servicePrincipals*') { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }
            $null = Get-MsecEntraAppAssignment -DisplayName 'nothing-matches-*' -WarningVariable w -WarningAction SilentlyContinue
            $w
        }

        "$warnings" | Should -Match 'NOT the same as the app having none'
    }

    It 'emits an Unreadable row when the assignments of an app cannot be read' {
        # A failed read must not silently shorten the answer.
        $rows = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*')     { throw 'Forbidden' }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @() } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }
            @(Get-MsecEntraAppAssignment -DisplayName 'app-one' -WarningAction SilentlyContinue)
        }

        $rows[0].PrincipalDisplayName    | Should -Be 'Unreadable'
        $rows[0].Application             | Should -Be 'app-one'
        $null -eq $rows[0].PrincipalType | Should -BeTrue
    }

    It 'refuses to enumerate the whole tenant when neither parameter is given' {
        # A [Parameter(Mandatory)] would PROMPT and hang a reporting pipeline instead.
        InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            { Get-MsecEntraAppAssignment } | Should -Throw '*every enterprise application*'
        }
    }

    It 'matches display names case-insensitively and de-duplicates overlapping patterns' {
        # Live display names were inconsistently cased ('CONTOSO-PROD-API' beside
        # 'contoso-prod-web'), and two patterns can hit the same app.
        $rows = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*') {
                    return @([pscustomobject]@{ id='a1'; principalType='Group'; principalId='g1'; principalDisplayName='Team'; appRoleId='r1'; createdDateTime='2024-01-01' })
                }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @([pscustomobject]@{ id='r1'; displayName='Operator' }) } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'CONTOSO-PROD-API'; appId = 'aid1' }) }
            }
            @(Get-MsecEntraAppAssignment -DisplayName '*-prod-api', 'contoso-prod-*')
        }

        # Matched by both patterns, reported once.
        @($rows).Count       | Should -Be 1
        $rows[0].Application | Should -Be 'CONTOSO-PROD-API'
    }

    It 'resolves each distinct user once even when assigned twice' {
        # One call per distinct user, not per assignment - the whole reason for the cache.
        InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Invoke-MsecGraphRequest -MockWith {
                if ($Path -like '*appRoleAssignedTo*') {
                    return @(
                        [pscustomobject]@{ id='a1'; principalType='User'; principalId='u1'; principalDisplayName='Ann'; appRoleId='r1'; createdDateTime='2024-01-01' }
                        [pscustomobject]@{ id='a2'; principalType='User'; principalId='u1'; principalDisplayName='Ann'; appRoleId='r2'; createdDateTime='2024-01-02' }
                    )
                }
                if ($Path -like '*/users/*')               { return [pscustomobject]@{ userPrincipalName = 'ann@contoso.com'; accountEnabled = $true } }
                if ($Path -like '*servicePrincipals/sp1*') { return [pscustomobject]@{ appRoles = @([pscustomobject]@{ id='r1'; displayName='A' }, [pscustomobject]@{ id='r2'; displayName='B' }) } }
                if ($Path -like '*servicePrincipals*')     { return @([pscustomobject]@{ id = 'sp1'; displayName = 'app-one'; appId = 'aid1' }) }
            }

            $rows = @(Get-MsecEntraAppAssignment -DisplayName 'app-one')

            # Two assignments (one per role), one distinct user, exactly one /users/ read.
            @($rows).Count | Should -Be 2
            $rows.Role | Should -Be @('A', 'B')
            Should -Invoke Invoke-MsecGraphRequest -Exactly 1 -ParameterFilter { $Path -like '*/users/*' }
        }
    }
}
