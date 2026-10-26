---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderIndicator

## SYNOPSIS
Every custom indicator of compromise in Defender for Endpoint - one row per indicator,
with what it matches, what it does, who created it and whether it ever expires.

## SYNTAX

```
Get-MsecDefenderIndicator [[-Type] <String[]>] [[-Action] <String[]>] [[-Value] <String>]
 [[-CreatedBy] <String>] [<CommonParameters>]
```

## DESCRIPTION
New-MsecDefenderIndicator could create one and nothing could list them, so the only way
to see what was already in place was the portal.
This answers "what are we already
blocking, allowing or auditing, and who decided that".

THIS API HAS NO READ-ONLY PERMISSION, WHICH MAKES THIS A Get-* THAT NEEDS A WRITE
SCOPE.
Listing indicators requires Ti.ReadWrite - normally through the Security
Administrator role - because Microsoft never shipped a Ti.Read.
That is surprising
enough to state before anything else: this command reads, but the permission it needs
can also write, and no narrower one exists to ask for.

IT RUNS ON THE Az CONTEXT, AS YOU - not as the msec app.
The app holds *.Read.All and
is deliberately NOT given Ti.ReadWrite: adding a write permission to the read-only
identity so that a read becomes convenient is exactly the trade this module refuses.
So this needs Connect-MsecAzure, and what you can see is what your own roles allow.

AN INDICATOR WITH NO EXPIRY NEVER EXPIRES, and that is the normal case rather than the
exception - measured on one tenant, 63 of 63 had no expirationTime at all.
ExpiresUtc
is $null for those, never a date far in the future, because "permanent" and "expires
in 2099" are different facts and a report that conflates them is lying quietly.

AN EMPTY SCOPE MEANS TENANT-WIDE, NOT UNSCOPED.
rbacGroupNames comes back empty when
an indicator applies to every device, which reads like missing data and is the
opposite - measured on the same tenant, 0 of 63 were scoped to a device group, so all
63 applied everywhere.
Scope is reported as 'Tenant-wide' rather than left blank.

COMMERCIAL CLOUD ONLY.
Defender for Endpoint has no securitycenter endpoint in the
sovereign clouds, so this throws there rather than returning an empty list.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderIndicator | Group-Object Action, Type | Sort-Object Count -Descending
```

What the tenant is actually enforcing, and in what proportion.
On one tenant: 36 Audit,
20 Block, 7 Allowed - so more than half of it was watching rather than stopping.

### EXAMPLE 2
```
Get-MsecDefenderIndicator -Action Allowed
```

The allow-list, which is the half of this worth reviewing most often - every entry is
something the product WOULD have stopped.

## PARAMETERS

### -Type
Indicator types to return - FileSha256, FileSha1, FileMd5, IpAddress, DomainName, Url,
CertificateThumbprint, WebCategory.
Matched case-insensitively against what the API
returns, and an unknown name is NOT an error: it filters to nothing and says so, since
Microsoft adds types without warning.

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

### -Action
Actions to return - Allowed, Audit, Block, BlockAndRemediate, Warn.
Same matching
rules as -Type.

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

### -Value
Wildcard filter on the indicator value itself, e.g.
'*.example.com' or a partial hash.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -CreatedBy
Wildcard filter on the creating account.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per indicator, PSTypeName 'MsecDefenderIndicator'. Raw keeps the
### untouched API object.
## NOTES
Needs Connect-MsecAzure and the Ti.ReadWrite scope on YOUR account - Security
Administrator or equivalent.
The msec app cannot do this and is not asked to.

## RELATED LINKS
