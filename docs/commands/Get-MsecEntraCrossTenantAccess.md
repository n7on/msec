---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraCrossTenantAccess

## SYNOPSIS
Cross-tenant access settings - which external tenants may collaborate, and which of
their security claims this tenant accepts in place of its own.

## SYNTAX

```
Get-MsecEntraCrossTenantAccess [-TrustingMfaOnly] [-BlockedOnly]
 [<CommonParameters>]
```

## DESCRIPTION
Cross-tenant access decides two things for every external organisation: whether their
users may be invited in at all, and whether their MFA and device claims are accepted
here.
Both are set once in a place nobody looks at again, and the defaults govern far
more partners than the explicit entries do.

AN INHERITED SETTING IS NOT A SETTING OF FALSE, AND THIS IS THE DEFECT THE COMMAND
EXISTS TO PREVENT.
Graph returns inboundTrust as NULL on a partner that has no override
- it inherits the tenant default - and null renders as blank or False in almost any
table.
If the default later turns MFA trust ON, every one of those partners silently
follows, while a report built from the raw field still shows them as not trusting.
TrustsMfa here is the EFFECTIVE value, resolved against the default; IsInherited says
whether the partner set it or merely follows.

THE DEFAULT ROW IS RETURNED AS A ROW, not as context for the others.
On a measured
tenant, four partners were configured - all IT suppliers - while the guests that
actually mattered, 25 from one CRO and 24 from another, had no entry at all and were
governed entirely by the default.
Reading only the partner list describes the
organisations someone once thought about, not the ones with access.

TRUSTING MFA CANNOT ADMIT AN UN-AUTHENTICATED USER, which is worth stating because the
setting is routinely read as a weakening.
It accepts an MFA claim the home tenant
actually issued; where the home tenant performed no MFA there is no claim, and a
Conditional Access policy requiring MFA still blocks.
What it avoids is making someone
who has already done MFA do it again here - in a tenant where the methods available to
a guest may well be weaker than the ones they just used.

Runs as the msec app.
Needs 'Policy.Read.All'.
Tenant names are resolved through
findTenantInformationByTenantId, which is unauthenticated tenant metadata; a tenant
that cannot be resolved reports its id rather than a blank.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraCrossTenantAccess
```

The default row plus every configured partner, with what each one's claims buy them.

### EXAMPLE 2
```
# Partners that merely follow the default - they move the moment the default moves.
Get-MsecEntraCrossTenantAccess | Where-Object IsInherited
```

## PARAMETERS

### -TrustingMfaOnly
Only entries whose effective setting accepts the partner's MFA claim.

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

### -BlockedOnly
Only entries where inbound B2B collaboration is blocked outright.

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

### PSCustomObject per scope, PSTypeName 'MsecEntraCrossTenantAccess'.
## NOTES
Read-only.
Read with Get-MsecEntraGuest: this says which organisations may hold
accounts here, that says which ones actually do.

## RELATED LINKS
