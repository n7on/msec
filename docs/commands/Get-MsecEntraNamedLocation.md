---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraNamedLocation

## SYNOPSIS
Named locations, whether each is marked trusted, and which Conditional Access policies
actually reference it - the networks the tenant treats as special, and what that buys.

## SYNTAX

```
Get-MsecEntraNamedLocation [-TrustedOnly] [-UnreferencedOnly]
 [<CommonParameters>]
```

## DESCRIPTION
A named location is a set of IP ranges or countries given a name so Conditional Access
can talk about it.
Marking one TRUSTED does two things: it lets a policy exclude it,
and it lowers the risk Identity Protection assigns to sign-ins from it.
Both are
privileges granted to a network rather than to a person.

A NAMED LOCATION NO POLICY REFERENCES DOES NOTHING AT ALL, however it is flagged.
UsedByPolicy lists the policies that name it and IsReferenced says whether any do, so
a trusted location nobody uses is visibly inert rather than alarming.
Measured on one
tenant: seven locations, six of them trusted, and exactly ONE policy referenced any of
them - which made six of the seven trust flags decorative.

AN EXCLUSION IN ONE POLICY IS NOT AN EXEMPTION, because Conditional Access grants are
ADDITIVE.
Every applicable policy must be satisfied, so a policy excluding trusted
locations only stands that policy down there; another policy covering the same user
still applies.
This is the mistake the ReferencedAs column exists to stop: on the same
tenant a Microsoft-managed MFA policy excluded AllTrusted and looked like an office-IP
MFA bypass for four admin accounts, until a second enabled policy was found covering
all four through a group with no location condition at all.
Reading one policy's
exclusion as an exemption would have reported a hole that was not there.

'AllTrusted' IS A TOKEN, NOT A LOCATION ID.
A policy excluding AllTrusted names no
location explicitly while applying to every location flagged trusted, so matching
policies on id alone finds nothing and reports the trusted locations as unreferenced.
Those policies are resolved against every trusted location and marked AllTrusted in
ReferencedAs.

Runs as the msec app.
Needs 'Policy.Read.All'.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraNamedLocation
```

### EXAMPLE 2
```
# Trusted, and actually used by a policy - the ones whose trust has an effect.
Get-MsecEntraNamedLocation -TrustedOnly | Where-Object IsReferenced
```

### EXAMPLE 3
```
# What each location covers, expanded.
Get-MsecEntraNamedLocation | Select-Object DisplayName, IsTrusted -ExpandProperty Ranges
```

## PARAMETERS

### -TrustedOnly
Only locations flagged trusted.

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

### -UnreferencedOnly
Only locations no Conditional Access policy references - the ones that currently do
nothing, whatever they are flagged as.

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

### PSCustomObject per named location, PSTypeName 'MsecEntraNamedLocation'.
## NOTES
Read-only.
An IP range is only as trustworthy as the network behind it: office egress
addresses are shared by every device on that network, guest Wi-Fi included unless it
egresses separately, so trusting one trusts everything behind it.

## RELATED LINKS
