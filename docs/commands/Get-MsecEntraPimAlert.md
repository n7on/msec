---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraPimAlert

## SYNOPSIS
Privileged Identity Management's own security alerts about the tenant's privileged
access - findings that reach no other product.

## SYNTAX

```
Get-MsecEntraPimAlert [-ActiveOnly] [-IncludeIncidents] [[-Scope] <String>] [<CommonParameters>]
```

## DESCRIPTION
PIM scans privileged access and raises its own findings: roles assigned outside PIM, too
many global administrators, roles that do not require multifactor authentication to
activate, stale accounts in privileged roles.
They are posture findings about
configuration, not detections of an event.

THESE ALERTS REACH NEITHER DEFENDER XDR NOR SENTINEL.
Verified on one tenant: 333
Defender XDR alerts over 30 days across Defender for Office 365, Defender for Cloud,
Sentinel, DLP and Defender for Endpoint, with no PIM product among them; and no row in
Sentinel's SecurityAlert mentioning PIM at all.
There is no connector that brings them.
The only trace that reaches a log is a single audit record when one is RESOLVED, which
names the alert after the fact and says nothing about what is active now - so without
this command, a live PIM alert is visible only to someone opening the PIM blade.

AN INACTIVE ALERT IS NOT AN ABSENT ONE, which is why every alert definition the tenant
scans for is returned with IsActive saying where it stands.
Returning only the firing
ones would make "we are not scanning for that" and "that is fine" look identical.

INCIDENT COUNT IS THE SIZE OF THE FINDING, not its severity.
'Roles are being assigned
outside Privileged Identity Management' with 104 incidents and with 1 are the same
alert at the same severity and very different problems.

THIS IS A BETA GRAPH ENDPOINT.
/beta/identityGovernance/roleManagementAlerts has no v1.0
equivalent at the time of writing, so the shape can change under it.
The command reads
it rather than pretending the data is unavailable, and this note is here so a future
failure is recognised as an API change rather than a tenant with nothing to report.

Needs 'RoleManagementAlert.Read.Directory'.
Global Reader does NOT cover it - measured:
the endpoint returns 403 to an app holding Global Reader and 20 other Graph permissions.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraPimAlert
```

Every PIM alert definition with where it stands, firing or not.

### EXAMPLE 2
```
Get-MsecEntraPimAlert -ActiveOnly | Sort-Object IncidentCount -Descending
```

What PIM currently objects to, biggest first.

### EXAMPLE 3
```
Get-MsecEntraPimAlert -ActiveOnly |
    Where-Object AlertName -match 'outside'
```

Whether roles are being assigned outside PIM - the finding that standing privilege is
accumulating by a route the activation record never shows.

## PARAMETERS

### -ActiveOnly
Only alerts currently firing.

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

### -IncludeIncidents
Fetch the incidents behind each alert - the specific roles, and for some alert types the
specific people.
One extra request per alert, so it is a switch rather than the default.
The incident shape VARIES BY ALERT TYPE: 'Roles don't require MFA for activation' names
only the role, while 'Eligible administrators aren't activating' names the assignee and
when they last activated.
Common fields are projected; Raw keeps the rest.

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

### -Scope
The scope to query.
'DirectoryRole' (default) covers Entra directory roles.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: DirectoryRole
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per alert, PSTypeName 'MsecEntraPimAlert'.
## NOTES
Pairs with Get-MsecEntraPimActivation, which shows the alert being resolved but never
the alert itself.

## RELATED LINKS
