BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'Msec.psd1') -Force

    # Defined here, not in the Describe body: a discovery-time variable is gone by the time an
    # It runs, which reads as the command returning nothing rather than as a test bug.
    $script:Locations = @(
        @{ id = 'loc-trusted'; displayName = 'HQ'; '@odata.type' = '#microsoft.graph.ipNamedLocation'
           isTrusted = $true; ipRanges = @(@{ cidrAddress = '10.0.0.0/24' }, @{ cidrAddress = '10.0.1.0/24' }) }

        @{ id = 'loc-guest'; displayName = 'Guest WiFi'; '@odata.type' = '#microsoft.graph.ipNamedLocation'
           isTrusted = $false; ipRanges = @(@{ cidrAddress = '192.0.2.0/24' }) }

        @{ id = 'loc-unused'; displayName = 'Old Office'; '@odata.type' = '#microsoft.graph.ipNamedLocation'
           isTrusted = $true; ipRanges = @(@{ cidrAddress = '198.51.100.0/24' }) }

        # A country location has NO isTrusted property at all - it cannot be trusted.
        @{ id = 'loc-country'; displayName = 'Blocked Countries'
           '@odata.type' = '#microsoft.graph.countryNamedLocation'
           countriesAndRegions = @('KP', 'IR'); includeUnknownCountriesAndRegions = $true }
    )
}

Describe 'Get-MsecEntraNamedLocation' {

    BeforeEach {
        InModuleScope msec { Mock Assert-MsecSession {} }
    }

    It 'expands AllTrusted to the trusted locations and not to the untrusted one' {
        # AllTrusted is a TOKEN, not an id. Matching policies on id alone finds nothing and
        # reports every trusted location as unreferenced - the opposite of the truth.
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @(@{ displayName = 'MFA policy'; state = 'enabled'
                            conditions = @{ locations = @{ excludeLocations = @('AllTrusted') } } })
            }
            $rows = Get-MsecEntraNamedLocation
            ($rows | Where-Object Id -eq 'loc-trusted').IsReferenced | Should -BeTrue
            ($rows | Where-Object Id -eq 'loc-guest').IsReferenced   | Should -BeFalse
            ($rows | Where-Object Id -eq 'loc-trusted').ReferencedAs | Should -Match 'Exclude:AllTrusted'
        }
    }

    It 'expands All to every location, trusted or not' {
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @(@{ displayName = 'Everywhere'; state = 'enabled'
                            conditions = @{ locations = @{ includeLocations = @('All') } } })
            }
            $rows = Get-MsecEntraNamedLocation
            @($rows | Where-Object IsReferenced).Count | Should -Be 4
            ($rows | Where-Object Id -eq 'loc-guest').ReferencedAs | Should -Match 'Include:All'
        }
    }

    It 'flags a location no policy names as unreferenced' {
        # A trusted location nobody uses does NOTHING. Reporting it as merely 'trusted' invites
        # a finding about a setting with no effect.
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @(@{ displayName = 'Named one'; state = 'enabled'
                            conditions = @{ locations = @{ includeLocations = @('loc-guest') } } })
            }
            $rows = Get-MsecEntraNamedLocation
            ($rows | Where-Object Id -eq 'loc-unused').IsReferenced | Should -BeFalse
            ($rows | Where-Object Id -eq 'loc-unused').UsedByPolicy | Should -BeNullOrEmpty
            (Get-MsecEntraNamedLocation -UnreferencedOnly).Id | Should -Not -Contain 'loc-guest'
        }
    }

    It 'records both the direction and the policy state' {
        # An Exclude is not an exemption - CA grants are additive - and a disabled policy
        # references nothing in practice. Both have to be visible on the row.
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @(@{ displayName = 'Off policy'; state = 'disabled'
                            conditions = @{ locations = @{ includeLocations = @('loc-trusted') } } })
            }
            $row = Get-MsecEntraNamedLocation | Where-Object Id -eq 'loc-trusted'
            $row.ReferencedAs | Should -Be @('Include (disabled)')
        }
    }

    It 'reports a country location as untrusted rather than inventing a trust flag' {
        # isTrusted does not exist on a country location; it cannot be trusted at all. False
        # here is the fact, not a default standing in for a missing property.
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @()
            }
            $c = Get-MsecEntraNamedLocation | Where-Object Id -eq 'loc-country'
            $c.LocationType            | Should -Be 'Country'
            $c.IsTrusted               | Should -BeFalse
            $c.Ranges                  | Should -Be @('KP', 'IR')
            $c.IncludeUnknownCountries | Should -BeTrue
        }
    }

    It 'lists IP ranges as CIDR strings' {
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @()
            }
            $hq = Get-MsecEntraNamedLocation | Where-Object Id -eq 'loc-trusted'
            $hq.Ranges     | Should -Be @('10.0.0.0/24', '10.0.1.0/24')
            $hq.RangeCount | Should -Be 2
        }
    }

    It '-TrustedOnly drops the untrusted locations, country ones included' {
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @()
            }
            (Get-MsecEntraNamedLocation -TrustedOnly).Id | Should -Be @('loc-trusted', 'loc-unused')
        }
    }

    It 'handles a tenant whose policies have no location conditions at all' {
        # The common case: every location unreferenced, and nothing should throw on the
        # absent includeLocations/excludeLocations properties.
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @(@{ displayName = 'No locations'; state = 'enabled'; conditions = @{} })
            }
            $rows = Get-MsecEntraNamedLocation
            @($rows).Count                          | Should -Be 4
            @($rows | Where-Object IsReferenced).Count | Should -Be 0
        }
    }

    It 'names the missing permission when Graph refuses' {
        InModuleScope msec {
            Mock Invoke-MsecGraphRequest { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecEntraNamedLocation } | Should -Throw '*Policy.Read.All*'
        }
    }

    It 'emits the documented type so the table view applies' {
        InModuleScope msec -Parameters @{ L = $script:Locations } {
            param($L)
            Mock Invoke-MsecGraphRequest {
                if ($Path -like '*namedLocations*') { return $L }
                return @()
            }
            (Get-MsecEntraNamedLocation)[0].PSObject.TypeNames |
                Should -Contain 'MsecEntraNamedLocation'
        }
    }
}
