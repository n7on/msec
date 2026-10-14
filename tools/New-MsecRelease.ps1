<#
.SYNOPSIS
    Prepares a msec release: bumps the manifest, opens the CHANGELOG entry, regenerates the
    docs, runs the suite, commits and tags. Stops before pushing.

.DESCRIPTION
    THE RELEASE VERSION COMES FROM THE GIT TAG, NOT FROM THE MANIFEST.
    .github/workflows/publish.yml triggers on a 'v*' tag and derives the version from the tag
    name, so the manifest is the one copy that can silently fall behind. This script exists so
    the sequence is one command rather than five things to remember in the right order.

    PUSHING THE TAG IS THE RELEASE. There is no later publish step to reconsider at, and a
    Gallery version cannot be deleted or replaced, only superseded. So this script stops after
    tagging and prints the push command. Running it never publishes anything.

    The order matters: the bump is committed BEFORE the tag is created, so the tag points at a
    commit that describes itself. Tagging first produces a release whose own manifest disagrees
    with it, which is what the workflow now refuses to build.

.PARAMETER Version
    The version to release, e.g. 0.6.0. Must be higher than the manifest's current version.

.PARAMETER SkipTests
    Skip the Pester suite. For re-running after a failure you have already investigated; the
    publish workflow runs the suite again and refuses to publish on a failure either way.

.EXAMPLE
    ./tools/New-MsecRelease.ps1 -Version 0.6.0 -WhatIf

    Shows every step without changing anything.

.EXAMPLE
    ./tools/New-MsecRelease.ps1 -Version 0.6.0

.NOTES
    Run from the repo root. Does not push. Does not publish.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
    [string] $Version,

    [switch] $SkipTests
)

$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $repoRoot 'Msec/Msec.psd1'
$changelog    = Join-Path $repoRoot 'CHANGELOG.md'
$tag          = "v$Version"

function Step { param([string] $Text) Write-Host "`n==> $Text" -ForegroundColor Cyan }

# ---- 1. The tree must be clean -----------------------------------------------------------
# A release is built from the tag, so anything uncommitted is simply absent from it. Finding
# that out afterwards means publishing a fix version.
Step 'Checking the working tree'
$dirty = @(git -C $repoRoot status --porcelain)
if ($dirty) {
    throw ("Working tree is not clean. Commit or stash first - the release is built from the " +
           "tag, so uncommitted work is left out of it:`n" + ($dirty -join "`n"))
}

if (@(git -C $repoRoot tag -l $tag)) { throw "Tag $tag already exists." }

# ---- 2. Version must move forwards -------------------------------------------------------
Step "Version"
$current = (Import-PowerShellDataFile $manifestPath).ModuleVersion
if ([version] $Version -le [version] $current) {
    throw "Version $Version is not higher than the current $current. The Gallery accepts each version once."
}
Write-Host "  $current -> $Version"

# ---- 3. CHANGELOG ------------------------------------------------------------------------
# Written before the tests so a failure here costs nothing. A release with no entry tells
# someone deciding whether to upgrade nothing at all.
Step 'CHANGELOG'
$raw = Get-Content $changelog -Raw
if ($raw -match "(?m)^##\s*\[$([regex]::Escape($Version))\]") {
    Write-Host "  entry for $Version already present"
}
else {
    $today  = (Get-Date).ToString('yyyy-MM-dd')
    $anchor = "(?m)^(##\s*\[\d+\.\d+\.\d+)"
    if ($raw -notmatch $anchor) { throw "Could not find an existing '## [x.y.z]' heading in CHANGELOG.md." }
    if ($PSCmdlet.ShouldProcess($changelog, "Insert '## [$Version] - $today'")) {
        $raw = [regex]::Replace($raw, $anchor, "## [$Version] - $today`n`n`$1", 1)
        Set-Content -Path $changelog -Value $raw -NoNewline
    }
    Write-Warning "Inserted an EMPTY '## [$Version]' heading. Write the entry before continuing - it is what people read to decide whether to upgrade."
}

# ---- 4. Manifest -------------------------------------------------------------------------
Step 'Manifest'
if ($PSCmdlet.ShouldProcess($manifestPath, "Set ModuleVersion to $Version")) {
    $m = Get-Content $manifestPath -Raw
    $m = [regex]::Replace($m, "ModuleVersion\s*=\s*'[^']*'", "ModuleVersion     = '$Version'", 1)
    Set-Content -Path $manifestPath -Value $m -NoNewline
    Write-Host "  ModuleVersion = $Version"
}

# ---- 5. Docs ------------------------------------------------------------------------------
Step 'Regenerating help'
if ($PSCmdlet.ShouldProcess('docs/commands', 'Regenerate')) {
    & (Join-Path $PSScriptRoot 'Update-MsecHelp.ps1')
}

# ---- 6. Tests -----------------------------------------------------------------------------
# Includes the manifest/CHANGELOG guards in MsecManifest.Tests.ps1, so a bump with no entry
# fails here rather than reaching the Gallery.
if ($SkipTests) { Write-Warning 'Skipping the test suite (-SkipTests).' }
else {
    Step 'Running the suite'
    if ($PSCmdlet.ShouldProcess('Msec/tests', 'Invoke-Pester')) {
        $result = Invoke-Pester -Path (Join-Path $repoRoot 'Msec/tests') -Output Normal -PassThru
        if ($result.FailedCount -gt 0) { throw "$($result.FailedCount) test(s) failed - not tagging." }
        Write-Host "  $($result.PassedCount) passed"
    }
}

# ---- 7. Commit and tag ---------------------------------------------------------------------
# Commit first: the tag must point at a commit whose manifest says $Version, which is exactly
# what the publish workflow verifies before it builds.
Step 'Committing and tagging'
if ($PSCmdlet.ShouldProcess($repoRoot, "Commit and tag $tag")) {
    git -C $repoRoot add -A
    git -C $repoRoot commit -q -m "Release $Version"
    git -C $repoRoot tag -a $tag -m $tag
    Write-Host "  committed and tagged $tag"
}

Step 'Ready - nothing has been published'
Write-Host @"
  Review:   git show $tag --stat
  PUBLISH:  git push origin main $tag      <- this publishes to the PowerShell Gallery
  Dry run:  gh workflow run publish.yml -f version=$Version -f dryRun=true

Pushing the tag triggers .github/workflows/publish.yml, which runs the suite again,
validates the manifest and pushes to the Gallery. That cannot be undone.
"@
