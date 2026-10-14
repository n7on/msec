---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewRetention

## SYNOPSIS
Retention labels and retention policies, with whether either is actually in force.

## SYNTAX

```
Get-MsecPurviewRetention [[-Kind] <String>] [<CommonParameters>]
```

## DESCRIPTION
Records management has two halves that are easy to mistake for one.
A retention LABEL
says what to do with an item; a retention POLICY says where the rule applies.
A label
with no policy publishing it does nothing at all, and the label list gives no hint of
that - which is how a tenant ends up appearing to have retention while retaining
nothing.

AN EMPTY POLICY LIST DOES NOT MEAN THERE ARE NO POLICIES.
Get-RetentionCompliancePolicy
is scoped by the connecting identity's compliance role groups, and an identity without
retention rights gets an EMPTY SET rather than access-denied.
Measured directly: an
app-only identity holding Global Reader returned 4 DLP policies, 3 sensitivity labels,
2 label policies, 60 alert policies and 1 retention LABEL - and 0 retention policies,
while the portal showed one.
The cmdlet existed, ran, and reported nothing.

That is the worst failure shape available: indistinguishable from a tenant with no
retention at all, and the conclusion it invites - "nothing is retained" - is exactly
the one a records-management report must not get wrong.
So a zero here always warns.
Reading retention policies needs a role group such as View-Only Retention Management;
Global Reader is not enough.

BOTH KINDS COME BACK IN ONE STREAM, tagged by Kind ('Label' or 'Policy'), because the
question is almost always "what retention do we have" rather than one or the other.
Use
-Kind to take a side.
IsInForce is the column that matters: false on an unpublished
label, false on a disabled policy.

AN EMPTY RESULT IS NOT AN ERROR AND THE COMMAND DOES NOT THROW ON ONE - but for the
policy half it is not a finding either.
A report should say "no retention policies were
visible to this identity", naming the limit, rather than "no retention is configured".
The label half is different: Get-ComplianceTag is readable under Global Reader, so an
empty label list can be reported as measured.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewRetention | Format-Table Kind, Name, Action, Duration, IsInForce
```

### EXAMPLE 2
```
# Labels that exist but are published by no policy, so retain nothing.
Get-MsecPurviewRetention -Kind Label | Where-Object { -not $_.IsInForce }
```

## PARAMETERS

### -Kind
Limit to 'Label' or 'Policy'.
Both by default.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per label or policy, PSTypeName 'MsecPurviewRetention'.
## NOTES
Needs Connect-Msec.
The compliance session is opened automatically on first use - that
handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
than done silently.
Call Connect-MsecPurview yourself to control -Organization, or to
choose when those 102 cmdlet names land in your runspace.

EXCHANGE MRM RETENTION IS A DIFFERENT SYSTEM AND IS NOT READ HERE.
Get-RetentionPolicy
and Get-RetentionPolicyTag live in the Exchange Online session, not the compliance one,
and govern mailboxes independently of everything above.
A tenant can show no Purview
retention while Exchange is deleting mail on a schedule, so "no retention" drawn from
this command alone is a statement about Purview only.

Read-only.

## RELATED LINKS
