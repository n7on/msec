---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecBusinessCentralAccess

## SYNOPSIS
Who holds which permission set in Business Central, across every environment and
company - including the Entra applications that Entra alone cannot tell you about.

## SYNTAX

```
Get-MsecBusinessCentralAccess [[-Environment] <String[]>] [-SuperOnly] [-ApplicationsOnly] [-IncludeDisabled] [<CommonParameters>]
```

## DESCRIPTION
The access review for the finance system.
One row per user per permission set per
company, with the user's state and licence type alongside, so "who has SUPER" is a
filter rather than an afternoon in the portal.

AN ENTRA APPLICATION'S REAL ACCESS IS NOT VISIBLE FROM ENTRA.
Service-to-service access
takes two steps in two systems: an application permission in Entra, and then a
separate record in Business Central's 'Microsoft Entra applications' page where the app
is enabled and assigned permission sets.
Entra shows only that an app MAY reach
Business Central; what it can touch is set here.
An app holding API.ReadWrite.All might
carry a trivial permission set, or a broad one, and Get-MsecEntraAppConsent cannot tell
the two apart.
IsApplication marks those principals.

BLANK COMPANY MEANS EVERY COMPANY, NOT NONE.
An assignment with Scope 'System' carries
an empty company, because it applies across the whole environment.
Rendering that as a
missing value - or filtering it out as incomplete - turns the broadest grant in the
system into the one that looks like nothing.
Company is reported as '(all companies)'
for exactly that reason.

A DISABLED USER STILL HAS ASSIGNMENTS, so State travels with every row.
A list of SUPER
holders that does not say which of them are disabled overstates the live exposure, and
one that silently drops them hides an account that need only be re-enabled.

userPermissionSets IS NOT USED, DELIBERATELY.
It returns HTTP 400 on some environments
and data on others within the same major version - measured on one tenant: working on
two environments and failing on three.
accessControls answers the same question and
works everywhere, so the flaky endpoint is avoided rather than wrapped in a retry that
would quietly return less from some environments than others.

Runs as the signed-in user - see the note below.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecBusinessCentralAccess -SuperOnly
```

Everyone with unrestricted access to the finance system, in every environment.

### EXAMPLE 2
```
Get-MsecBusinessCentralAccess -SuperOnly |
    Where-Object { $_.AuthenticationEmail -notlike '*@contoso.com' }
```

External parties holding unrestricted access - partners, consultants, technicians.

### EXAMPLE 3
```
Get-MsecBusinessCentralAccess -ApplicationsOnly |
    Select-Object Environment, UserName, RoleId, AppName
```

What each service-to-service integration can actually do, which Entra does not show.

### EXAMPLE 4
```
Get-MsecBusinessCentralAccess | Group-Object Environment, RoleId |
    Sort-Object Count -Descending
```

The shape of permission assignment across the estate.

## PARAMETERS

### -Environment
Limit to named environments.
All of them by default.

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

### -SuperOnly
Only assignments of SUPER - the permission set the product documents as "This role has
all permissions."

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

### -ApplicationsOnly
Only Entra application principals, not people.

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

### -IncludeDisabled
Include assignments held by disabled users.
Excluded by default, because a review of
live access should not be padded with accounts that cannot sign in - they are still
reachable with -IncludeDisabled, and the count of what was hidden is reported.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per assignment, PSTypeName 'MsecBusinessCentralAccess'.
## NOTES
RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP - see Get-MsecBusinessCentralEnvironment
for why.
Needs Connect-AzAccount, not Connect-Msec.

## RELATED LINKS
