---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraAppAssignment

## SYNOPSIS
Who is assigned to an enterprise application - the portal's "Users and groups" blade -
one row per assignment.

## SYNTAX

```
Get-MsecEntraAppAssignment [[-DisplayName] <String[]>] [[-AppId] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
This is the access-review question: which people and which groups can use this app, and
in which role.
It is NOT the consent question.
Get-MsecEntraAppConsent reads the same
Graph collection and deliberately keeps only ServicePrincipal principals, because those
are application permissions granted TO software.
This command keeps the other side -
User and Group - which is who may USE the app.

A GROUP IS REPORTED AS A GROUP, NOT EXPANDED.
The portal shows the group; so does this.
A row saying a group is assigned does not tell you how many people that is, and treating
the row count as a headcount will undercount badly - four of these apps carry four group
assignments each.
Expand with Get-MsecEntraGroupMember when the review needs names.

A PRINCIPAL CAN HOLD SEVERAL ROLES, AND EACH IS ITS OWN ROW.
Counting rows counts
assignments, not people.
Measured on four live apps: 37 rows, of which 21 were user
assignments - held between just 6 distinct people.
Reporting that as 21 users overstates
the review by more than three times.
Group by PrincipalId for a headcount.

THE UPN IS NOT IN THE ASSIGNMENT AND COSTS A CALL PER USER.
appRoleAssignedTo carries
principalDisplayName and principalId only, so UserPrincipalName and UserEnabled come
from a second Graph read per DISTINCT user, cached within the call.
Display names are
not unique and say nothing about whether the account still works, which is most of what
an access review is for - measured on four live apps, 21 users across 37 assignments.

UserEnabled IS THE COLUMN THAT FINDS THE STALE ONES.
An assignment survives the user
being disabled; nothing cleans it up.

A PATTERN THAT MATCHES NOTHING WARNS.
An app that was renamed, or a wildcard that misses,
would otherwise return an empty result identical to an app with no assignments - and on
a monthly review that reads as "nobody has access" rather than "we did not look".
Named
apps are easy to miss: a prefix search for four similarly named apps in a live tenant
turned up a FIFTH carrying an extra suffix, which an obvious wildcard would exclude.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
    Format-Table Application, PrincipalType, PrincipalDisplayName, Role, UserEnabled
```

The monthly access review, as the portal would show it.

### EXAMPLE 2
```
# Assignments left behind by people whose accounts are disabled.
Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
    Where-Object { $_.UserEnabled -eq $false }
```

### EXAMPLE 3
```
# People, not assignments - a principal holding three roles is one person.
Get-MsecEntraAppAssignment -DisplayName 'contoso-prod-*' |
    Group-Object PrincipalId | Measure-Object | Select-Object -ExpandProperty Count
```

## PARAMETERS

### -DisplayName
Enterprise application display names.
Wildcards are supported and matching is
case-insensitive, which matters - display names in a live tenant were inconsistently
cased ('CONTOSO-PROD-API' beside 'contoso-prod-web').

A wildcard pattern is matched client-side, so the service principals are enumerated
first.
Graph cannot filter on an arbitrary pattern.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AppId
Application (client) ids, as an alternative to -DisplayName.
Exact match, no wildcards.

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

### One PSCustomObject per assignment, PSTypeName 'MsecEntraAppAssignment'.
## NOTES
Needs Connect-Msec and the 'Application.Read.All' application permission to read the
service principals and their assignments, plus a directory read ('User.Read.All' or
'Directory.Read.All') for UserPrincipalName and UserEnabled.
Verified against a live
tenant on the permissions the msec app already holds.

'Unreadable' in UserPrincipalName means the user lookup FAILED, not that the user has
no UPN.
A warning names how many, and UserEnabled is $null for those rows - a failed
read must never render as a clean one.

## RELATED LINKS
