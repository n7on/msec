---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecSentinelIncident

## SYNOPSIS
One row per Microsoft Sentinel incident, read from the workspace itself rather than
from Defender XDR - including the ones XDR has never seen.

## SYNTAX

```
Get-MsecSentinelIncident [[-SubscriptionId] <String>] [[-ResourceGroupName] <String>]
 [[-WorkspaceName] <String>] [[-Status] <String>] [[-Days] <Int32>] [-AnyAge] [-IncludeEntities] [<CommonParameters>]
```

## DESCRIPTION
PROVIDERNAME IS THE WHOLE REASON THIS EXISTS.
A Sentinel workspace that was in use
before it was connected to Defender XDR keeps those older incidents with
ProviderName 'Azure Sentinel'.
They are never synced to XDR, so
Get-MsecDefenderIncident cannot see them at all - measured on one workspace, 628 of
3,721 incidents, and 53 of the 248 still open.

AND THE SecurityIncident TABLE IS NOT A SUBSTITUTE.
That table ages out with workspace
retention - 31 days on the workspace measured - while the incidents themselves live in
ARM far longer: the oldest OPEN incident found this way was created 21 months earlier.
So an incident can be simultaneously open, invisible to XDR, and absent from KQL.
Both
of the obvious places to look return nothing, and nothing looks like 'clean'.

IT PAGES, AND NOT PAGING IS A SILENT TRUNCATION.
The API caps a page well below the
total; the same workspace returned 3,721 incidents over four pages at the largest
page size, and still had a nextLink after six pages at a smaller one.
A single GET
returns a confident, short, wrong answer.

ENTITIES COST A POST PER INCIDENT, which is why -IncludeEntities is opt-in.
The call
is POST .../incidents/{name}/entities and it is a READ despite the verb - it changes
nothing.
On a few hundred incidents it roughly doubles the runtime.

IT RUNS ON THE Az CONTEXT, AS YOU.
Sentinel is an Azure resource, so this is Azure RBAC
rather than Graph: the msec app holds Graph permissions and cannot read this.
Needs
Microsoft Sentinel Reader on the workspace.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecSentinelIncident -WorkspaceName contoso-sentinel -Status New |
    Group-Object ProviderName
```

The split that matters: anything under 'Azure Sentinel' is invisible to
Get-MsecDefenderIncident and will not be triaged by anyone working from XDR.

### EXAMPLE 2
```
Get-MsecSentinelIncident -WorkspaceName contoso-sentinel |
    Where-Object { $_.Status -ne 'Closed' -and $_.ProviderName -eq 'Azure Sentinel' } |
    Sort-Object CreatedUtc
```

The backlog nobody can see from Defender, oldest first.

## PARAMETERS

### -SubscriptionId
Subscription to read.
Defaults to the active Az context.

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

### -ResourceGroupName
Narrows the workspace search.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WorkspaceName
A single workspace.
Without it, every Sentinel-onboarded workspace in scope is read.

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

### -Status
New, Active or Closed.
Filtered server-side.
Omit for every status.

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

### -Days
Only incidents CREATED in the last N days.
Filters on createdTimeUtc, not on last
modified - 'what was opened recently' and 'what was touched recently' are different
questions and this answers the first.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -AnyAge
Send no date filter at all.
The default is also no filter; -AnyAge exists to say so
explicitly in a script that might otherwise look like it forgot -Days.

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

### -IncludeEntities
Fetch the entities for each incident - accounts, IPs, hosts, URLs, cloud applications.
One extra request per incident; see the description.

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

### One PSCustomObject per incident, PSTypeName 'MsecSentinelIncident'. Etag is carried so
### Set-MsecSentinelIncident can write without clobbering a concurrent change. Raw keeps
### the untouched ARM object.
## NOTES
Needs Connect-MsecAzure and Microsoft Sentinel Reader on the workspace.
Runs as YOU,
not as the msec app.

## RELATED LINKS
