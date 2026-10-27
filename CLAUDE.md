# msec

## Role and responsibilities

This agent (session `msec-29`) **owns the `msec` PowerShell module** - the code in this repo
and its releases to the PowerShell Gallery.

- **Owns (may change):** everything in this repo. Commands in `msec/public/`, tests in
  `msec/tests/`, bundled KQL in `msec/kql/`, generated help in `docs/commands/`, the manifest,
  `CHANGELOG.md` and `README.md`.
- **Reads, never changes:** every Microsoft tenant the module queries. msec is a
  **read-only posture module**. Its app registration holds `*.Read.All` and nothing else.
- **Always needs a human:** publishing to the PowerShell Gallery, pushing a tag (a tag push
  *is* a publish - see `.github/workflows/publish.yml`), and any `git push`. A Gallery release
  cannot be deleted, only superseded.
- **Not its job:** the SIEM Terraform (`siem-d2`), security documentation (`security-23`,
  `~/source/Security`), the Application Gateway repo (`ag-51`). Documentation changes go to
  `security-23` by message rather than being edited directly.

Hard limits are enforced in `.claude/settings.json`.

## THIS REPO IS PUBLIC

`github.com/n7on/msec`, published to the PowerShell Gallery. Its history was reset once
already to remove tenant identifiers.

**Never commit:** tenant ids, subscription ids, Key Vault names, workspace names, resource
group names, app/client ids, user principal names, device names, internal hostnames or IPs.
Examples use placeholders - `kv-msec`, `contoso.com`, `00000000-0000-0000-0000-000000000000`.

This applies to `CLAUDE.md` and `.claude/` too: they are published with everything else. Where
the house standard asks for connector names, IDs and paths, this repo carries the role and the
conventions and **omits the coordinates**.

Measured figures from real tenants are fine and are the house style - *"measured on one
workspace, 0 of 48 rules had it enabled"* - as long as nothing identifies the tenant.

`git grep` only searches **tracked** files. A new command that has never been added is
invisible to it, which is how twelve identifiers survived the last scrub. Check the working
tree, not just the index.

## Two identities, and the module keeps them apart

| | Reads | Writes |
| --- | --- | --- |
| **How** | The app registration, certificate in Key Vault | The signed-in user, via `Connect-MsecAdmin` |
| **Holds** | `*.Read.All` application permissions | Whatever the human's roles allow |
| **Commands** | `Get-*`, `Search-*`, `Measure-*` | `Set-*`, `New-*` |

The certificate's private key never leaves Key Vault; signing happens inside it. **Never fetch
or reproduce a secret value**, and never add a write permission to the read app to make
something easier.

Azure-plane commands (`Get-MsecSentinelRule`, `Get-MsecAzureSecureScore`,
`Search-MsecAzureResourceGraph`) run on the **Az context**, not the app - Sentinel is an Azure
resource and the app holds Graph permissions, not Azure RBAC. Say so in the command's help.

## Writing a command

The module's value is that its output can be trusted without re-checking it. That is what the
conventions protect.

- **Help carries the traps, not a description of the obvious.** Lead a paragraph with the trap
  in capitals, then explain. `Get-MsecDefenderAlert` opens with
  *"SERVICESOURCE IS OFTEN 'unknownFutureValue', AND THAT IS THE API, NOT THE DATA."* Someone
  reading the output needs to know that before they draw a conclusion from it.
- **State what was measured, and on what.** "measured on a live tenant, 231 of 569 alerts in
  ninety days - 40%". Never present a guess as a figure.
- **"Could not read" and "there is nothing" must never look the same.** This is the single
  most important rule here. `Get-MsecIntuneDeviceCompliance` returns `Unreadable` when a call
  failed and `Unattributed` when it succeeded and returned nothing; collapsing them made the
  same tenant report 4 devices one run and 9 the next. Warn when part of a result could not be
  read, rather than returning a quietly short answer.
- **`$null` is not `0` and not `''`.** `ResolveDays` is `$null` while an alert is open, never
  `0`. `Query` is `$null` on a Fusion rule, never `''` - an empty string claims a query exists
  and is blank.
- **An empty result from a filter is a result; an empty result from a missing permission is
  not.** Name the permission in the error when a call 403s.
- **Date filters answer different questions.** `-Days` filters creation, `-UpdatedWithin`
  filters last touch, `-AnyAge` sends no filter at all. Asking "what has been worked recently"
  with `-Days` returns a confident wrong answer - that is how a tenant with 431 triaged alerts
  was first read as having almost none.
- **Heuristics say so.** `QueryTables` scans KQL rather than parsing it, and its help says that
  empty means "none found", never "reads nothing".
- **Don't drop data because this tenant's copy is thin.** The module is public and other people
  have different data.

### Checklist for any command change

1. Write or update the command in `msec/public/`.
2. Tests in `msec/tests/`, including a regression test for every bug found - name the symptom.
3. `pwsh -c "Invoke-Pester -Path msec/tests"` - all green.
4. `pwsh -File tools/Update-MsecHelp.ps1` to regenerate `docs/commands/`.
5. A `CHANGELOG.md` entry under the unreleased version, saying what was wrong and what it cost.

Use the `msec-command` skill for a new command and `msec-release` to ship.

**Releases run from `tools/New-MsecRelease.ps1`.** The version comes from the git tag, not from
the manifest, so the manifest is the one copy that can drift - the script does the sequence in
the order that keeps them together, and stops before pushing.

## Testing notes

- Pester 5 runs `Describe` bodies during **discovery**, so a helper function declared there
  does not exist when `It` blocks run. Put helpers in `BeforeAll`.
- `InModuleScope -Parameters` variables are **not in scope inside a mock body** that runs
  later. Assign them to `$script:` in module scope first. This has cost a debugging session
  twice.
- PowerShell variable names are **case-insensitive**: a local `$domain` *is* the `-Domain`
  parameter and will silently overwrite it.
- A `[Parameter(Mandatory)]` **hangs** a non-interactive caller rather than failing it -
  PowerShell prompts and nothing answers. Reporting pipelines consume this module, so prefer a
  runtime check with a clear `throw`.

## Git

- **Anton is the only author.** Never add a `Co-Authored-By` trailer.
- The author identity is already in this repo's git config and differs from the one used in
  the work repos. Let the config supply it; don't override it with `-c user.email`.
- Commit messages straight to the point: what changed and why it was wrong before.
- Don't commit or push unless asked.
