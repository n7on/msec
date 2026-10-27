---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderAlert

## SYNOPSIS
One row per Defender XDR alert across every workload - endpoint, Office 365,
identity, cloud apps and DLP - with the incident it belongs to.

## SYNTAX

```
Get-MsecDefenderAlert [[-Days] <Int32>] [[-UpdatedWithin] <Int32>] [-AnyAge] [[-Severity] <String[]>]
 [[-Status] <String[]>] [[-ServiceSource] <String[]>] [[-Classification] <String[]>]
 [[-Determination] <String[]>] [[-TriagedBy] <String[]>]
 [<CommonParameters>]
```

## DESCRIPTION
Alerts are the detections; incidents are the groupings Defender builds from them.
Get-MsecDefenderIncident answers "what is being investigated"; this answers "what
actually fired", which is the level at which a noisy detector or an unworked queue
becomes visible.

SERVICESOURCE IS OFTEN 'unknownFutureValue', AND THAT IS THE API, NOT THE DATA.
Graph
returns that placeholder for a source the API version does not have a name for yet.
Measured on a live tenant, 231 of 569 alerts in ninety days - 40% - came back that
way.
It is reported verbatim rather than guessed at or folded into 'other', because
the alternative is inventing a source attribution that Microsoft did not make.
ProductName and DetectionSource are carried alongside and are often populated when
ServiceSource is not.

STATUS VOCABULARY DIFFERS FROM INCIDENTS.
An alert is 'new', 'inProgress' or
'resolved'; an incident is 'active', 'inProgress', 'resolved' or 'redirected'.
An
alert is never 'active'.
Filtering both with the same string finds nothing in one of
them, silently.

RESOLVEDAYS IS $null WHILE AN ALERT IS OPEN, never 0 - the same reasoning as the
incident command.
Here it is computed from ResolvedUtc, which Graph populates
properly, rather than inferred from the last update.

EVIDENCE IS NOT FLATTENED.
Every alert carries an evidence array - devices, users,
files, IP addresses, mailboxes - with a different shape per entity type.
Flattening it
would either lose most of it or produce a column set that changes per row, so the
count is reported and the array stays on Raw.evidence for anything that needs it.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecDefenderAlert -Days 90 -Severity high | Sort-Object CreatedUtc -Descending
```

### EXAMPLE 2
```
# The unworked queue: high-severity alerts nobody has picked up.
Get-MsecDefenderAlert -Days 90 -Severity high -Status new |
    Format-Table CreatedUtc, Title, ServiceSource, IncidentId
```

### EXAMPLE 3
```
# Which detectors produce the most noise.
Get-MsecDefenderAlert -Days 90 | Group-Object Title |
    Sort-Object Count -Descending | Select-Object -First 15
```

## PARAMETERS

### -Days
How far back to look at CREATION time.
Default 30.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 30
Accept pipeline input: False
Accept wildcard characters: False
```

### -UpdatedWithin
Alerts last TOUCHED within this many days, whatever their age.
Use this for triage
history: -Days finds alerts RAISED in a window, so an alert raised a year ago and
worked last week is absent from it at every value short of 365.
Replaces the
created-date filter rather than narrowing it.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -AnyAge
NO DATE FILTER AT ALL, for the question "what is open, however old".
-Days and
-UpdatedWithin both cap at 365, so neither can answer it, and reaching for a large
-Days is not the same thing: an item older than the cap is invisible rather than
merely old.
That gap is how a backlog gets reported as empty.

The result is still bounded - by Graph's own retention on these endpoints, not by
anything chosen here - so "any age" means "as far back as the service will answer".

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

### -Severity
Only these severities: informational, low, medium, high.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Status
Only these statuses: new, inProgress, resolved.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ServiceSource
Only alerts from these workloads, matched case-insensitively against ServiceSource -
e.g.
microsoftDefenderForEndpoint, microsoftDefenderForOffice365, dataLossPrevention.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Classification
The recorded triage verdict.
'unknown' is what an untouched alert carries, so
-Classification unknown selects the UNtriaged set.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Determination
The recorded cause behind the classification, e.g.
notMalicious, securityTesting,
malware.
'unknown' means nobody recorded one.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -TriagedBy
Matches assignedTo.
NOT always a person - 'Suppression rule' and
'MdcAlertsResourceProvider' appear here too, and neither is a human verdict.
Name the
analysts explicitly when the output is going to be learned from.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per alert, PSTypeName 'MsecDefenderAlert'.
## NOTES
Needs Connect-Msec.
Documented as 'SecurityAlert.Read.All'; measured on a live tenant
the endpoint also answers for an app holding SecurityIncident.Read.All and
SecurityEvents.Read.All, both of which New-MsecApp grants - so it works today without
an extra consent.
If a tenant answers 403, that permission is the one to add.

## RELATED LINKS
