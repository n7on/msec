BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'msec.psd1') -Force

    # Defined here, not in the Describe body: a variable set at discovery time is gone by the
    # time an It runs, which reads as the command returning nothing rather than as a test bug.
    #
    # The shapes that matter are the sign-in ones. 'active-nonint' is the account that an
    # interactive-only reading calls dormant while it signs in every day.
    $script:Guests = @(
        @{ id = 'g1'; displayName = 'Pending Pat'; mail = 'pat@partner.com'
           userPrincipalName = 'pat_partner.com#EXT#@t.onmicrosoft.com'
           accountEnabled = $true; createdDateTime = '2024-01-01T00:00:00Z'
           externalUserState = 'PendingAcceptance'; creationType = 'Invitation' }

        @{ id = 'g2'; displayName = 'Active Alex'; mail = 'alex@partner.com'
           userPrincipalName = 'alex_partner.com#EXT#@t.onmicrosoft.com'
           accountEnabled = $true; createdDateTime = '2024-01-01T00:00:00Z'
           externalUserState = 'Accepted'; creationType = 'Invitation'
           signInActivity = @{ lastSignInDateTime = (Get-Date).AddDays(-2).ToString('o') } }

        @{ id = 'g3'; displayName = 'Nonint Nina'; mail = 'nina@other.com'
           userPrincipalName = 'nina_other.com#EXT#@t.onmicrosoft.com'
           accountEnabled = $true; createdDateTime = '2024-01-01T00:00:00Z'
           externalUserState = 'Accepted'; creationType = 'Invitation'
           # Interactive EMPTY, non-interactive yesterday - in daily use.
           signInActivity = @{ lastSignInDateTime = $null
                               lastNonInteractiveSignInDateTime = (Get-Date).AddDays(-1).ToString('o') } }

        @{ id = 'g4'; displayName = 'Stale Sam'; mail = 'sam@other.com'
           userPrincipalName = 'sam_other.com#EXT#@t.onmicrosoft.com'
           accountEnabled = $false; createdDateTime = '2023-01-01T00:00:00Z'
           externalUserState = 'Accepted'; creationType = 'Invitation'
           signInActivity = @{ lastSignInDateTime = (Get-Date).AddDays(-400).ToString('o') } }
    )
}

Describe 'Get-MsecEntraGuest' {

    BeforeEach {
        InModuleScope msec { Mock Assert-MsecSession {} }
    }

    It 'counts a non-interactive sign-in as a sign-in' {
        # THE DEFECT THIS COMMAND EXISTS TO AVOID. lastSignInDateTime is interactive only, so
        # an account used daily through refresh tokens leaves it empty. Reading that field
        # alone puts a live account on the deletion list.
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            $nina = Get-MsecEntraGuest | Where-Object Mail -eq 'nina@other.com'
            $nina.LastSignInUtc  | Should -Not -BeNullOrEmpty
            $nina.LastSignInKind | Should -Be 'NonInteractive'
            (Get-MsecEntraGuest -NeverSignedIn).Mail | Should -Not -Contain 'nina@other.com'
        }
    }

    It 'reports the latest of the three timestamps, not whichever is present' {
        InModuleScope msec {
            $newest = (Get-Date).AddDays(-1)
            Mock Invoke-MsecGraphRequest {
                @(@{ id = 'x'; mail = 'x@y.com'; externalUserState = 'Accepted'; accountEnabled = $true
                     signInActivity = @{
                         lastSignInDateTime               = (Get-Date).AddDays(-30).ToString('o')
                         lastNonInteractiveSignInDateTime = (Get-Date).AddDays(-1).ToString('o')
                         lastSuccessfulSignInDateTime     = (Get-Date).AddDays(-10).ToString('o')
                     } })
            }
            $row = Get-MsecEntraGuest
            [int]($newest - $row.LastSignInUtc).TotalDays | Should -Be 0
            $row.LastSignInKind | Should -Be 'NonInteractive'
        }
    }

    It 'warns and flags the rows when NO guest carries sign-in data' {
        # Graph omits signInActivity silently, without error, when AuditLog.Read.All is
        # missing. Every guest then looks never-used - a list that reads as safe to delete and
        # is nothing of the kind. It must be impossible to mistake for a measurement.
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest {
                @(@{ id = 'a'; mail = 'a@b.com'; externalUserState = 'Accepted'; accountEnabled = $true }
                  @{ id = 'b'; mail = 'b@b.com'; externalUserState = 'Accepted'; accountEnabled = $true })
            }
            $warnings = @()
            $rows = Get-MsecEntraGuest -WarningVariable warnings -WarningAction SilentlyContinue
            ($warnings -join ' ') | Should -Match 'AuditLog.Read.All'
            ($warnings -join ' ') | Should -Match 'NOT evidence'
            $rows.SignInDataAvailable | Should -Not -Contain $true
        }
    }

    It 'does not warn when at least one guest has sign-in data' {
        # A genuinely-never-signed-in guest alongside an active one is a measurement, not a
        # permission problem, and warning there would train people to ignore the warning.
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            $warnings = @()
            $rows = Get-MsecEntraGuest -WarningVariable warnings -WarningAction SilentlyContinue
            ($warnings -join ' ') | Should -Not -Match 'AuditLog.Read.All'
            $rows.SignInDataAvailable | Should -Not -Contain $false
        }
    }

    It '-PendingOnly returns the unredeemed invitations' {
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            (Get-MsecEntraGuest -PendingOnly).Mail | Should -Be @('pat@partner.com')
        }
    }

    It '-InactiveDays excludes guests that never signed in at all' {
        # Never-signed-in and inactive-for-N-days are different findings. Merging them makes a
        # row ambiguous about which it is, and -NeverSignedIn already answers the other one.
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            $stale = Get-MsecEntraGuest -InactiveDays 180
            $stale.Mail | Should -Be @('sam@other.com')
            $stale.Mail | Should -Not -Contain 'pat@partner.com'
        }
    }

    It '-NeverSignedIn returns only accounts with no signal of any kind' {
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            (Get-MsecEntraGuest -NeverSignedIn).Mail | Should -Be @('pat@partner.com')
        }
    }

    It 'takes the domain from mail rather than the mangled guest UPN' {
        # A guest UPN is alex_partner.com#EXT#@tenant.onmicrosoft.com - splitting it on @ gives
        # the HOST tenant, which would group every guest under one domain.
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            $rows = Get-MsecEntraGuest
            $rows.Domain | Should -Not -Contain 't.onmicrosoft.com'
            ($rows | Where-Object Mail -eq 'alex@partner.com').Domain | Should -Be 'partner.com'
        }
    }

    It '-Domain filters on the guest home domain' {
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            (Get-MsecEntraGuest -Domain 'other.com').Mail |
                Should -Be @('nina@other.com', 'sam@other.com')
        }
    }

    It 'falls back to the UPN when a guest has no mail address' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest {
                @(@{ id = 'n'; mail = $null
                     userPrincipalName = 'nomail_partner.com#EXT#@t.onmicrosoft.com'
                     externalUserState = 'Accepted'; accountEnabled = $true })
            }
            (Get-MsecEntraGuest).Mail | Should -Be 'nomail_partner.com#EXT#@t.onmicrosoft.com'
        }
    }

    It 'names the missing permission when Graph refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraGuest } | Should -Throw '*User.Read.All*'
        }
    }

    It 'emits the documented type so the table view applies' {
        InModuleScope msec -Parameters @{ G = $script:Guests } {
            param($G)
            Mock Invoke-MsecGraphRequest { return $G }
            (Get-MsecEntraGuest)[0].PSObject.TypeNames | Should -Contain 'MsecEntraGuest'
        }
    }
}
