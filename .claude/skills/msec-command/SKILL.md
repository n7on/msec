---
name: msec-command
description: Add a new command to the msec PowerShell module, or change an existing one - help that carries the traps, tests including regressions, regenerated docs and a CHANGELOG entry. Use when the user wants a new Get-Msec*/Search-Msec*/Measure-Msec* command, or a new parameter or property on an existing one.
---

# msec command

A command earns its place by answering a question the portal answers badly or not at all, and
by being trustworthy enough that nobody re-checks its output by hand. Most of the work is in
the help and the edge cases, not the API call.

## Before writing

1. Find the question. "Which devices are non-compliant" was already answered;
   `Get-MsecIntuneDeviceCompliance` exists because **why** was not.
2. Check it isn't a parameter on an existing command. `-AnyAge`, `-UpdatedWithin` and
   `Evidence` were all gaps found by using the module for a real investigation, and each
   belonged on a command that already existed.
3. Decide which identity it runs on - the app (Graph, read-only) or the Az context (Azure
   plane). Say which in the help, and why.
4. Call the endpoint once by hand and look at the real shape. Polymorphic fields, placeholder
   values like `unknownFutureValue`, and properties that are present-but-empty are all
   discovered this way and all belong in the help.

## Shape

`Msec/public/<Verb>-Msec<Noun>.ps1`, one command per file, approved verb.

```powershell
function Get-MsecThing {
    <#
    .SYNOPSIS
        One sentence: what one row is.

    .DESCRIPTION
        What it answers that nothing else does.

        A TRAP IN CAPITALS, THEN THE EXPLANATION. One paragraph per trap, each opening with
        the thing a reader must know before drawing a conclusion. Include the measurement:
        "measured on a live tenant, 231 of 569 alerts in ninety days - 40%".

    .PARAMETER Thing
        What it filters, and what it does NOT filter.

    .EXAMPLE
        Get-MsecThing -Days 90 | Group-Object Title | Sort-Object Count -Descending

        What the reader learns from this, not what the code does.

    .OUTPUTS
        One PSCustomObject per <thing>, PSTypeName 'MsecThing'.

    .NOTES
        Needs Connect-Msec and the '<Permission>.Read.All' application permission.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    Assert-MsecSession
    # ...
}
```

Then: add it to `FunctionsToExport` in `Msec/Msec.psd1`, and a view in
`Msec/Msec.format.ps1xml` if the default table is unreadable.

## Rules that decide the hard cases

- **Separate "could not read" from "nothing there."** Different category values, and a
  `Write-Warning` naming how many reads failed. A throttled call must never render as a clean
  result.
- **`$null` where a value is unknown or not applicable.** Never `0`, never `''`.
- **Name the permission on a 403**, in the thrown message.
- **Report placeholders verbatim.** Don't fold `unknownFutureValue` into "other" - that invents
  an attribution Microsoft did not make.
- **Flatten for reading, keep the original.** `Evidence` is a readable array; `Raw` keeps
  everything.
- **Say when a result is bounded** - by retention, by a cap, by a plan tier.
- **A heuristic says it is one**, in the help, with what an empty result means.

## Finishing

1. Tests in `Msec/tests/<Command>.Tests.ps1`. Cover the trap each help paragraph describes, and
   add a regression test named after the symptom for every bug found on the way.
2. `pwsh -c "Invoke-Pester -Path Msec/tests -Output Detailed"` - all green.
3. `pwsh -File tools/Update-MsecHelp.ps1` - regenerates `docs/commands/` and audits the help.
4. `CHANGELOG.md` entry under the unreleased version: what was wrong, what it cost, what
   changed. Capitalised lead sentences, same as the help.
5. Verify against a live tenant where possible, and put the measured figure in the help.

Don't commit unless asked. See `CLAUDE.md` for authorship.
