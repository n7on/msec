---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraAccessPackage

## SYNOPSIS
Entra entitlement-management access packages with the policy that governs each one -
who may request it, whether anyone approves, and whether the access ever ends.

## SYNTAX

```
Get-MsecEntraAccessPackage [-NoExpiry] [-SelfRequestable] [-NoApproval] [[-Catalog] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
The standing-privilege review for entitlement management.
One row per access package per
assignment policy, because the policy is where the controls live: a package on its own
says what access exists, and says nothing about who can get it or for how long.

APPROVAL AND EXPIRY ARE DIFFERENT CONTROLS AND ARE EASILY CONFLATED.
Approval governs
WHO GETS IN.
Expiry governs HOW LONG THEY STAY.
A package that requires approval and
never expires is not time-boxed access that someone signed off - it is permanent access
that someone signed off once.
Measured on one tenant: all 77 policies required approval,
and 69 of them never expired, including 25 packages granting directory administrator
roles.
Reading only the approval column would have called that fully governed.

'never' IS PRINTED, NOT LEFT BLANK.
An empty expiry cell reads as "not configured yet",
which invites the reader to assume a default applies.
noExpiration IS the configuration
and it means permanent, so it is rendered as a value.

WHAT A PACKAGE GRANTS IS USUALLY A GROUP, NOT A ROLE.
Resource roles come back as
AadGroup/Member far more often than as a directory role, so the access the package
confers is whatever that group carries - which the package itself does not state.
A
package named for an administrator role may add the member to a group holding a
permanent role assignment, an eligible one, or nothing at all.
ResourceRole is reported
as what it is; resolving the group's own privilege is Get-MsecEntraRoleHolder's job, and
the two are meant to be read together.

ResourceRole IS A string\[\] so a caller can test it exactly with -contains.
Joining the
entries into one string would force -like '*Administrator*' on every such query, and a
substring match happily reports 'Helpdesk Administrator' as a hit for 'Administrator'.

A PACKAGE WITH NO POLICY STILL APPEARS, with Policy null and the control columns blank.
Such a package cannot be requested by anyone, so it grants nothing - but dropping it
from the output would hide a package that exists and could be given a policy tomorrow.

Runs as the msec app.
Needs 'EntitlementManagement.Read.All'; these endpoints also
answer to the Global Reader directory role, so a tenant where that is held may work
without the grant - which is a side effect to rely on deliberately, not by accident.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraAccessPackage -NoExpiry
```

Every package whose access, once granted, is permanent.

### EXAMPLE 2
```
Get-MsecEntraAccessPackage -SelfRequestable -NoApproval
```

Access anyone in the directory can give themselves unprompted.
An empty result here is
a good answer and worth stating as one.

### EXAMPLE 3
```
Get-MsecEntraAccessPackage -NoExpiry |
    Where-Object { $_.Package -match 'Administrator' } |
    Select-Object Catalog, Package, AllowedTargetScope, Approvers
```

Permanent administrator access, and who signed it off.

### EXAMPLE 4
```
Get-MsecEntraAccessPackage | Group-Object ApprovalRequired, Expiration
```

The shape of the estate - the combination is the finding, not either column alone.

## PARAMETERS

### -NoExpiry
Only policies whose access never expires.

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

### -SelfRequestable
Only policies any member of the directory may request (allowedTargetScope
'allMemberUsers'), as opposed to a named set of users.

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

### -NoApproval
Only policies that grant without anyone approving.

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

### -Catalog
Limit to one or more catalogs by display name.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per package/policy pair, PSTypeName 'MsecEntraAccessPackage'.
## NOTES
Read-only.
Pairs with Get-MsecEntraRoleHolder: this says what a package grants, that
says what the granted group actually carries.

## RELATED LINKS
