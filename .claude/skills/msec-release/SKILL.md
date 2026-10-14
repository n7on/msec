---
name: msec-release
description: Release a version of the msec module to the PowerShell Gallery - version bump, CHANGELOG, full test run, dry run, tag and publish. Use when the user wants to ship a new version, cut a release, or publish to the Gallery.
---

# msec release

**A Gallery release is permanent.** It cannot be deleted or replaced, only superseded by a
higher version. Everything below exists to make the last cheap failure happen before the push,
not after.

**Pushing a tag `v*` publishes.** `.github/workflows/publish.yml` triggers on the tag, so there
is no separate "publish" step to reconsider at. The tag push is the release.

Consumers install **unversioned** (`Install-Module Msec` in the reporting pipelines), so a
broken release reaches them on their next run without anyone choosing to upgrade.

## Before anything

Confirm the version with the user, and show them the CHANGELOG entry. Publishing is
outward-facing and irreversible - never infer the go-ahead.

## The short version

```bash
./tools/New-MsecRelease.ps1 -Version <x.y.z>        # add -WhatIf to see it first
```

That does steps 1-6 below in the right order and stops before pushing. Prefer it to doing
them by hand; the order is the part that goes wrong.

Then, only with the user's explicit go-ahead:

```bash
git push origin main v<x.y.z>     # THIS PUBLISHES
```

## What the script does, and why each step is there

**1. Refuses a dirty tree.** The release is built from the tag, so uncommitted work is simply
absent from it - discovered afterwards, that costs a fix version.

**2. Refuses a version that does not move forwards.** The Gallery accepts each version once.

**3. Opens the CHANGELOG entry** with today's date, and warns that it is empty. Write it.
Someone deciding whether to upgrade reads this and nothing else.

**4. Bumps `ModuleVersion`** in `Msec/Msec.psd1`.

**5. Regenerates `docs/commands/`** via `tools/Update-MsecHelp.ps1`.

**6. Runs the full suite, then commits and tags - in that order.** The commit comes before the
tag so the tag points at a commit whose manifest already states the version. Tagging first
produces a release that disagrees with itself, and the workflow now refuses to build that.

It never pushes and never publishes.

## The guards behind it

- `Msec/tests/MsecManifest.Tests.ps1` fails when `ModuleVersion` has no matching CHANGELOG
  entry, when it is not the newest entry, or when it is malformed. CI runs on every push and
  pull request.
- `.github/workflows/publish.yml` **fails** when the manifest disagrees with the tag. It used
  to patch the mismatch for its own build and emit a warning - which is plain log text in
  Actions, so a forgotten bump published cleanly and left the repo describing a version it
  never shipped.

CI does not run on tags, so the workflow guard is the only thing standing between a bad tag
and the Gallery.

## Dry run

```bash
gh workflow run publish.yml -f version=<x.y.z> -f dryRun=true
gh run watch
```

Installs dependencies, runs the suite, runs `Test-ModuleManifest`, imports the module and
checks every name in `FunctionsToExport` exists - then packs with `-WhatIf` and pushes nothing.
Worth doing for any release that adds commands.

## 7. Confirm

```bash
gh run list --workflow=publish.yml --limit 1
pwsh -c "Find-Module msec -Repository PSGallery | Format-List Name, Version, PublishedDate"
```

The Gallery takes a few minutes to index. The workflow also creates a GitHub release with
generated notes.

## If it goes wrong

A bad version cannot be withdrawn - publish a higher one that fixes it. If it is actively
harmful, unlist it in the Gallery UI (existing installs keep working; `Install-Module` stops
resolving to it) and say so in the CHANGELOG.

Check `PSGALLERY_API_KEY` is set as a repo secret if the publish step fails on a missing key.
Never print, echo or paste the key.
