#Requires -Module Pester
#
# Tests for Get-MsecEntraPimActivation and Get-MsecEntraPimAlert.
#
# The central trap, and the reason -WithoutMfa exists in the shape it does:
#
#   IsAuthenticatedWithMfa IS ABSENT FROM MOST PIM RECORDS. Measured on one tenant over 30
#   days: of 118 activations, 40 carried the field as true, 78 did not carry it at all, and
#   NONE carried it as false. Defaulting the absence to $false would have reported 78
#   privileged activations as unauthenticated - a fabricated finding, and the loudest kind.
#   So the property is $null when unrecorded and -WithoutMfa matches $false only.
#
#   An unreadable duration is $null, not 0: an activation whose window could not be parsed is
#   not one that lasted no time.
#
#   A PIM alert that is not firing is a MEASUREMENT, not an absence - so IsActive carries it
#   rather than the alert being dropped from the output.

BeforeAll { Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psm1') -Force -ErrorAction Stop }
AfterAll { Remove-Module msec -Force -ErrorAction SilentlyContinue }

Describe 'Get-MsecEntraPimActivation' {
    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId='t'; ClientId='c'; KeyVaultName='kv'; KeyName='k'
                                     ThumbprintBytes=[byte[]](1..20); Tokens=@{} }
        }
    }

    It 'leaves MFA null when unrecorded, and -WithoutMfa matches only an explicit false' {
        $r = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:58:54Z'; activityDisplayName='Add member to role completed (PIM activation)'
                        category='RoleManagement'; result='success'
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='a@contoso.com' } }
                        targetResources=@([pscustomobject]@{ displayName='Global Administrator' })
                        additionalDetails=@(
                            [pscustomobject]@{ key='AuditType'; value='ActivateRole' }
                            [pscustomobject]@{ key='IsAuthenticatedWithMfa'; value='True' }
                            [pscustomobject]@{ key='Justification'; value='sec work' }) }
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:27:41Z'; activityDisplayName='Add member to role completed (PIM activation)'
                        category='ResourceManagement'; result='success'
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='b@contoso.com' } }
                        targetResources=@([pscustomobject]@{ displayName='Contributor' })
                        # No IsAuthenticatedWithMfa at all - the common case.
                        additionalDetails=@([pscustomobject]@{ key='AuditType'; value='ActivateRole' }) }
                    [pscustomobject]@{ activityDateTime='2026-10-11T08:00:00Z'; activityDisplayName='Add member to role completed (PIM activation)'
                        category='RoleManagement'; result='success'
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='c@contoso.com' } }
                        targetResources=@([pscustomobject]@{ displayName='User Administrator' })
                        additionalDetails=@(
                            [pscustomobject]@{ key='AuditType'; value='ActivateRole' }
                            [pscustomobject]@{ key='IsAuthenticatedWithMfa'; value='False' }) }
                )
            }
            [pscustomobject]@{
                All        = @(Get-MsecEntraPimActivation -Days 30)
                WithoutMfa = @(Get-MsecEntraPimActivation -Days 30 -WithoutMfa)
            }
        }

        $r.All.Count | Should -Be 3
        ($r.All | Where-Object Actor -eq 'a@contoso.com').AuthenticatedWithMfa | Should -BeTrue
        # NOT $false. Absent means "not recorded on this record type".
        ($r.All | Where-Object Actor -eq 'b@contoso.com').AuthenticatedWithMfa | Should -BeNullOrEmpty
        ($r.All | Where-Object Actor -eq 'c@contoso.com').AuthenticatedWithMfa | Should -Be $false

        # The whole point: only the explicit false. Counting the unrecorded one here would
        # manufacture a privileged-access finding out of a missing field.
        $r.WithoutMfa.Count  | Should -Be 1
        $r.WithoutMfa.Actor  | Should -Be 'c@contoso.com'
    }

    It 'computes duration from the activation window, and leaves it null when either end is missing' {
        $rows = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:00:00Z'; category='RoleManagement'
                        targetResources=@([pscustomobject]@{ displayName='Global Administrator' })
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='a@x' } }
                        additionalDetails=@(
                            [pscustomobject]@{ key='AuditType'; value='ActivateRole' }
                            [pscustomobject]@{ key='StartTime'; value='2026-10-12T08:00:00Z' }
                            [pscustomobject]@{ key='ExpirationTime'; value='2026-10-12T16:00:00Z' }) }
                    [pscustomobject]@{ activityDateTime='2026-10-12T09:00:00Z'; category='RoleManagement'
                        targetResources=@([pscustomobject]@{ displayName='User Administrator' })
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='b@x' } }
                        additionalDetails=@([pscustomobject]@{ key='AuditType'; value='ActivateRole' }) }
                )
            }
            @(Get-MsecEntraPimActivation -Days 30)
        }

        ($rows | Where-Object Actor -eq 'a@x').DurationHours | Should -Be 8
        # $null, not 0 - a window that could not be read is not a zero-length activation.
        ($rows | Where-Object Actor -eq 'b@x').DurationHours | Should -BeNullOrEmpty
    }

    It 'keeps both PIM scopes and narrows to activations only on request' {
        $r = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:00:00Z'; category='RoleManagement'
                        targetResources=@([pscustomobject]@{ displayName='Global Administrator' })
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='a@x' } }
                        additionalDetails=@([pscustomobject]@{ key='AuditType'; value='ActivateRole' }) }
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:10:00Z'; category='ResourceManagement'
                        targetResources=@([pscustomobject]@{ displayName='Contributor' })
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName='b@x' } }
                        additionalDetails=@([pscustomobject]@{ key='AuditType'; value='ActivateRole' }) }
                    [pscustomobject]@{ activityDateTime='2026-10-12T08:20:00Z'; category='RoleManagement'
                        targetResources=@([pscustomobject]@{ displayName='Alert' })
                        initiatedBy=[pscustomobject]@{ user=[pscustomobject]@{ userPrincipalName=$null } }
                        additionalDetails=@([pscustomobject]@{ key='AuditType'; value='ResolveAlert' }) }
                )
            }
            [pscustomobject]@{
                All         = @(Get-MsecEntraPimActivation -Days 30)
                Activations = @(Get-MsecEntraPimActivation -Days 30 -ActivationsOnly)
            }
        }

        # Azure resource PIM logs here too - dropping it would halve the picture.
        $r.All.Count | Should -Be 3
        @($r.All | Where-Object Scope -eq 'ResourceManagement').Count | Should -Be 1
        $r.Activations.Count | Should -Be 2
        @($r.Activations | Where-Object AuditType -eq 'ResolveAlert').Count | Should -Be 0
    }

    It 'refuses a window longer than the directory audit log retains' {
        { Get-MsecEntraPimActivation -Days 60 } | Should -Throw
    }
}

Describe 'Get-MsecEntraPimAlert' {
    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId='t'; ClientId='c'; KeyVaultName='kv'; KeyName='k'
                                     ThumbprintBytes=[byte[]](1..20); Tokens=@{} }
        }
    }

    It 'returns alerts that are not firing, because quiet is a measurement' {
        $r = InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith {
                @(
                    [pscustomobject]@{ id='a1'; isActive=$true; incidentCount=104; scopeType='DirectoryRole'
                        alertDefinition=[pscustomobject]@{ id='d1'; displayName='Roles are being assigned outside of Privileged Identity Management'
                                                           severityLevel='medium'; description='...' } }
                    [pscustomobject]@{ id='a2'; isActive=$false; incidentCount=0; scopeType='DirectoryRole'
                        alertDefinition=[pscustomobject]@{ id='d2'; displayName='There are too many global administrators'
                                                           severityLevel='low'; description='...' } }
                )
            }
            [pscustomobject]@{
                All    = @(Get-MsecEntraPimAlert)
                Active = @(Get-MsecEntraPimAlert -ActiveOnly)
            }
        }

        # Both returned by default: "PIM scanned and found nothing" and "PIM does not scan for
        # this" must not look identical, which dropping the quiet one would cause.
        $r.All.Count    | Should -Be 2
        $r.Active.Count | Should -Be 1
        $r.Active.AlertName | Should -Match 'outside of Privileged Identity Management'
        $r.Active.IncidentCount | Should -Be 104
    }

    It 'rewrites a 403 to say the Global Reader role does not cover this endpoint' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraPimAlert } | Should -Throw '*RoleManagementAlert.Read.Directory*'
            { Get-MsecEntraPimAlert } | Should -Throw '*Global Reader*'
        }
    }

    It 'names a beta-endpoint failure as an API change rather than an empty tenant' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 404 (Not Found).' }
            { Get-MsecEntraPimAlert } | Should -Throw '*BETA*'
        }
    }
}
