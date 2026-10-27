#Requires -Module Pester
#
# Guards the manifest against the whole test suite's blind spot.
#
# Every other test runs inside InModuleScope, which can see functions the module does NOT
# export. So a new command in Public/ that never made it into FunctionsToExport passes every
# test, generates its help, and is simply absent when someone imports the module. That has
# happened here.
#
# These tests compare the filesystem to the manifest, from OUTSIDE the module, which is the
# only place the discrepancy is visible.
#
# The version tests exist for a different silent failure. THE RELEASE VERSION COMES FROM THE
# GIT TAG, NOT FROM THIS MANIFEST: .github/workflows/publish.yml triggers on 'v*' and derives
# the version from the tag name. Nothing stopped the manifest from being left behind, and the
# publish workflow patched the mismatch for its own build and carried on - so the Gallery got
# the right version while the repo kept describing one it never shipped. CI runs on every push
# and pull request, and a tag is neither, so this is the last place a forgotten bump is cheap
# to catch.

BeforeAll {
    $script:ModuleRoot   = Join-Path $PSScriptRoot '..'
    $script:ManifestPath = Join-Path $script:ModuleRoot 'Msec.psd1'

    $script:Exported = @((Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop).ExportedFunctions.Keys)
    $script:PublicFunctions = @(
        Get-ChildItem -Path (Join-Path $script:ModuleRoot 'public') -Filter '*.ps1' -File |
            ForEach-Object BaseName
    )

    $script:Version   = (Import-PowerShellDataFile -Path $script:ManifestPath).ModuleVersion
    $script:Changelog = Get-Content -Path (Join-Path $script:ModuleRoot '..' 'CHANGELOG.md') -Raw
    # Headings are '## [0.5.0] - 2026-10-12'. Captured in file order, which is newest first.
    $script:LoggedVersions = @([regex]::Matches($script:Changelog, '(?m)^##\s*\[(\d+\.\d+\.\d+(?:\.\d+)?)\]') |
                               ForEach-Object { $_.Groups[1].Value })
}

Describe 'Msec.psd1' {
    It 'exports every command in Public/' {
        # The failure this exists for: the file is there, the function is defined, the tests
        # pass, and Get-Command finds nothing because the manifest was never updated.
        $missing = @($script:PublicFunctions | Where-Object { $_ -notin $script:Exported })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'every Public/*.ps1 must be in FunctionsToExport'
    }

    It 'exports nothing that no longer exists' {
        # The other direction: a command removed from Public/ but left in the manifest. The
        # module still imports, but Test-ModuleManifest reports a command nobody can call.
        $orphaned = @($script:Exported | Where-Object { $_ -notin $script:PublicFunctions })
        $orphaned -join ', ' | Should -BeNullOrEmpty -Because 'FunctionsToExport must not name a command with no file'
    }

    It 'exports the file name, so Public/ is the source of truth' {
        # One function per file, named for the file. The two checks above only mean anything
        # if that convention holds - a file defining a differently-named function would pass
        # both while exporting nothing usable.
        foreach ($name in $script:PublicFunctions) {
            $path = Join-Path $script:ModuleRoot "public/$name.ps1"
            $content = Get-Content -Path $path -Raw
            $content | Should -Match "function\s+$([regex]::Escape($name))\s*\{" -Because "$name.ps1 should define function $name"
        }
    }
}

Describe 'Msec.psd1 version' {
    It 'has a CHANGELOG entry for the version in the manifest' {
        # Someone deciding whether to upgrade reads the CHANGELOG, and a release with no entry
        # tells them nothing about what changed or whether it breaks them. The manifest is the
        # only version this repo states, so it is the one that must be documented.
        $script:LoggedVersions |
            Should -Contain $script:Version -Because "CHANGELOG.md needs a '## [$($script:Version)]' heading before $($script:Version) can be released"
    }

    It 'has a CHANGELOG entry that is not empty' {
        # THE GUARD THIS ADDS. Checking only that the heading EXISTS let 0.7.0 ship with three
        # empty '## [0.7.0]' headings and the real entry still under [Unreleased] - the tests
        # were green throughout, because a heading was present. A release whose entry says
        # nothing is the same as a release with no entry to the person reading it.
        $raw = Get-Content (Join-Path $PSScriptRoot '..' '..' 'CHANGELOG.md') -Raw
        $pattern = "(?ms)^##\s*\[$([regex]::Escape($script:Version))\][^\n]*\n(.*?)(?=^##\s*\[|\z)"
        $m = [regex]::Match($raw, $pattern)

        $m.Success | Should -BeTrue -Because "CHANGELOG.md needs a '## [$($script:Version)]' heading"
        $m.Groups[1].Value.Trim() |
            Should -Not -BeNullOrEmpty -Because "the '## [$($script:Version)]' entry is empty - write what changed before releasing"
    }

    It 'leaves no empty version heading anywhere in the CHANGELOG' {
        # Same bug seen from the other side: New-MsecRelease once inserted a heading above
        # EVERY previous release, so the damage was not limited to the version being cut.
        $raw = Get-Content (Join-Path $PSScriptRoot '..' '..' 'CHANGELOG.md') -Raw
        $empty = [regex]::Matches($raw, "(?ms)^(##\s*\[[^\]]+\][^\n]*)\n\s*(?=^##\s*\[)") |
                     ForEach-Object { $_.Groups[1].Value.Trim() } |
                     Where-Object { $_ -notmatch '\[Unreleased\]' }

        $empty -join ', ' | Should -BeNullOrEmpty -Because 'a version heading with nothing under it tells a reader nothing'
    }

    It 'has the manifest version at the top of the CHANGELOG' {
        # Catches a bump that went backwards, or a typo like 0.50 for 0.5.0: both leave a valid
        # heading somewhere in the file while the newest entry describes something else.
        $script:LoggedVersions | Select-Object -First 1 |
            Should -Be $script:Version -Because 'the newest CHANGELOG entry must be the version being developed'
    }

    It 'is a version the Gallery will accept' {
        # A malformed version reaches the Gallery as a permanent, unlistable release. The
        # publish workflow rejects one too, but that is after the tag has been pushed.
        "$($script:Version)" | Should -Match '^\d+\.\d+\.\d+(\.\d+)?$'
    }
}
