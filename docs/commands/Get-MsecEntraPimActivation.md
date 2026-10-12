---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraPimActivation

## SYNOPSIS
Privileged Identity Management activity from the directory audit log - who activated
which privileged role, for how long, with what justification, and whether MFA was used.

## SYNTAX

```
Get-MsecEntraPimActivation [[-Days] <Int32>] [-ActivationsOnly] [-WithoutMfa] [-NoJustification]
 [[-Role] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
The record of privileged access actually being USED, as opposed to who holds it.
Get-MsecEntraRoleHolder answers "who could be an administrator"; this answers "who was
one, when, and why".

ACTIVATION IS NOT THE ONLY THING HERE.
loggedByService 'PIM' covers the whole lifecycle:
activations and their expiry, eligible assignments added and removed, role settings
changed, and PIM's own alerts being resolved.
AuditType says which.
-ActivationsOnly
narrows to activations when that is the question, and the rest is left in by default
because "someone changed a PIM role setting" belongs in the same timeline as "someone
activated the role it governs".

MFA IS $null WHEN IT WAS NOT RECORDED, NEVER $false.
IsAuthenticatedWithMfa is present
on activation records and absent on most others.
Defaulting the absence to false would
report every role-setting change as an unauthenticated action, and would bury the
finding that actually matters - an activation that genuinely carried no MFA - in noise
that is merely unrecorded.
Filtering with -WithoutMfa therefore matches $false only.

BOTH PIM SCOPES ARE RETURNED.
Entra directory roles and Azure resource roles both log
here, distinguished by Category: 'RoleManagement' is the directory, 'ResourceManagement'
is Azure RBAC.
Measured on one tenant over 30 days: 62 directory activations and 54
Azure resource activations - dropping either would halve the picture, so Scope is a
column rather than a filter applied silently.

JUSTIFICATION IS FREE TEXT AND MAY BE ABSENT.
Where PIM does not require one, the field
is simply missing, which is not the same as a user declining to give one - the role
setting decides.
Read an empty Justification alongside Get-MsecEntraPimPolicy, which
says whether that role demanded it.

THE WINDOW IS THE AUDIT LOG'S, NOT PIM'S.
Directory audit retention is 30 days on Entra
ID P1/P2 and 7 days without, so -Days is capped at 30 and a tenant without P1 will
return less than asked for without saying so - that limit is the tenant's licence, not
this command.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraPimActivation -Days 30 -ActivationsOnly |
    Group-Object Actor, Role | Sort-Object Count -Descending
```

Who activates what, and how often.

### EXAMPLE 2
```
Get-MsecEntraPimActivation -Days 30 -ActivationsOnly -WithoutMfa
```

Privileged roles activated without multifactor authentication.
An empty result is a
good answer and worth reporting as one.

### EXAMPLE 3
```
Get-MsecEntraPimActivation -Days 30 -ActivationsOnly -Role 'Global Administrator' |
    Select-Object ActivityDateTime, Actor, Justification, DurationHours, IpAddress
```

Every Global Administrator activation, with the reason given.

### EXAMPLE 4
```
Get-MsecEntraPimActivation -Days 30 | Where-Object AuditType -eq 'ResolveAlert'
```

PIM's own alerts being resolved - the only trace of them that reaches any log, since
PIM alerts do not flow to Defender XDR or Sentinel.

## PARAMETERS

### -Days
How far back to look.
Default 7, maximum 30 - the directory audit retention ceiling.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### -ActivationsOnly
Only role activations, excluding expiry, eligibility changes and setting changes.

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

### -WithoutMfa
Only records where MFA was explicitly NOT used.
Records that never carried the field
are excluded - see the description.

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

### -NoJustification
Only records with no justification text.

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

### -Role
Limit to one or more role display names.
Case-insensitive, matched as a substring so
'Administrator' catches every administrator role.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per audit record, PSTypeName 'MsecEntraPimActivation'.
## NOTES
Needs 'AuditLog.Read.All', which the msec app already holds.
Pairs with
Get-MsecEntraPimPolicy (what activation demands) and Get-MsecEntraRoleHolder (who holds
the role at all).

## RELATED LINKS
