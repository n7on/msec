---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Set-MsecSentinelIncident

## SYNOPSIS
Change a Microsoft Sentinel incident - status, classification, owner or severity -
including the ones Defender XDR cannot see.

## SYNTAX

### ByNumber (Default)
```
Set-MsecSentinelIncident -Number <Int32> -WorkspaceName <String> [-SubscriptionId <String>]
 [-ResourceGroupName <String>] [-Status <String>] [-Classification <String>] [-ClassificationReason <String>]
 [-ClassificationComment <String>] [-Owner <String>] [-Severity <String>] [-PassThru] [-WhatIf] [-Confirm] [<CommonParameters>]
```

### ByName
```
Set-MsecSentinelIncident -Name <String> -WorkspaceName <String> [-SubscriptionId <String>]
 [-ResourceGroupName <String>] [-Status <String>] [-Classification <String>] [-ClassificationReason <String>]
 [-ClassificationComment <String>] [-Owner <String>] [-Severity <String>] [-PassThru] [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
The write half of Get-MsecSentinelIncident.
Set-MsecDefenderIncident cannot touch an
incident whose ProviderName is 'Azure Sentinel', because it never reaches the XDR
incident API at all.

THE API HAS NO PATCH, ONLY PUT, AND PUT REPLACES THE RESOURCE.
Sending just the fields
being changed silently discards everything else on the incident - owner, labels,
description, the original title.
So this GETs the incident first and puts the existing
properties back alongside the change.
Any hand-written script that skips the GET is
quietly destroying data it never read.

THE ETAG IS CONCURRENCY CONTROL, NOT DECORATION.
It is sent as If-Match, so a write
fails rather than overwriting a change somebody made between the read and the write -
which, on a shared incident queue, is a thing that happens.

A CLASSIFICATION NEEDS A REASON, EXCEPT WHEN IT MUST NOT HAVE ONE.
BenignPositive,
TruePositive and FalsePositive each require -ClassificationReason; Undetermined
requires its absence.
Checked here so the failure names the rule, rather than arriving
as a bare 400 from ARM.

CLASSIFICATION ONLY APPLIES TO A CLOSED INCIDENT.
The API accepts classification
fields only when status is Closed, so passing -Classification without -Status Closed
is refused here rather than silently ignored.

IT RUNS ON THE Az CONTEXT, NOT ON Connect-MsecAdmin - UNLIKE Set-MsecDefenderIncident,
and that difference is forced rather than chosen.
Defender XDR incidents are a Graph
resource reached with delegated Graph scopes; Sentinel incidents are an ARM resource
reached with Azure RBAC.
An ARM endpoint will not accept a Graph token, so there is no
version of this command that uses the admin session.
Needs Microsoft Sentinel Responder
on the workspace.
The msec app holds Graph permissions and is deliberately not given
this.

ACCOUNTABILITY IS THE SAME; THE CEREMONY IS NOT.
Both commands write as a named human -
Sentinel records the change under your own UPN - so "writes belong to a person" still
holds.
What differs is that the Az context is already present and cached, where
Connect-MsecAdmin wants a browser.
That makes this runnable unattended, which is
genuinely useful and is also the thing to be deliberate about: Azure RBAC tends to be
STANDING, broader and quieter than a Graph admin consent, so the role on the workspace
is worth reviewing as carefully as the consent would have been.

-Confirm IS THE REMAINING CHECKPOINT.
ConfirmImpact is High, so an interactive caller
is asked before every write and an unattended one has to pass -Confirm:$false on
purpose.
That explicit opt-out is what replaces the sign-in prompt - do not scatter it
through a script to silence the noise.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecSentinelIncident -WorkspaceName contoso-sentinel |
    Where-Object { $_.Status -eq 'New' -and $_.ProviderName -eq 'Azure Sentinel' } |
    Set-MsecSentinelIncident -WorkspaceName contoso-sentinel -Status Closed `
        -Classification BenignPositive -ClassificationReason SuspiciousButExpected `
        -ClassificationComment 'Pre-XDR backlog, reviewed in bulk' -WhatIf
```

Dry-run the backlog nobody could close from Defender.
Drop -WhatIf to commit.

## PARAMETERS

### -Number
The incident number as shown in the portal.
Resolved to the underlying GUID by reading
the workspace first.

```yaml
Type: Int32
Parameter Sets: ByNumber
Aliases:

Required: True
Position: Named
Default value: 0
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -Name
The incident's GUID, as returned by Get-MsecSentinelIncident.
Skips the lookup.

```yaml
Type: String
Parameter Sets: ByName
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -WorkspaceName
The workspace holding the incident.
Required - an incident number is only unique
within one workspace.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -SubscriptionId
Subscription to act in.
Defaults to the active Az context.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ResourceGroupName
Narrows the workspace search.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Status
New, Active or Closed.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Classification
Why the incident was closed.
Requires -Status Closed.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ClassificationReason
Required for BenignPositive, TruePositive and FalsePositive; must be omitted for
Undetermined.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ClassificationComment
Free text recorded with the closure.
Worth writing - it is the only part of a closed
incident that explains the decision to the next reader.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Owner
UPN to assign.
Pass an empty string to unassign.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Severity
High, Medium, Low or Informational.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Emit the incident as it stands after the change.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per incident changed, with the before and after of each field
### touched. With -PassThru, the full incident instead.
## NOTES
Needs Connect-MsecAzure and Microsoft Sentinel Responder on the workspace.
Runs as
YOU, not as the msec app.

## RELATED LINKS
