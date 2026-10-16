---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecContext

## SYNOPSIS
One row per session surface - Azure, the msec app, the write session and each
workload - with the tenant it is bound to and whether that matches the others.

## SYNTAX

```
Get-MsecContext [-IncludeWorkload] [-List] [<CommonParameters>]
```

## DESCRIPTION
ANSWERS "WHERE AM I?", WHICH NOTHING ELSE DOES.
Working with msec means up to seven
separate sessions: the Az context, the app-only session from Connect-Msec, the
delegated session from Connect-MsecAdmin, and one each for Exchange, Teams,
SharePoint and Purview.
Each is established by its own command, each remembers its
own tenant, and nothing has ever shown them together.
Finding out which tenant a
given command was about to use meant running something and inferring it from the
answer.

A STALE SESSION IS THE FAILURE THIS EXISTS FOR, NOT A MISSING ONE.
An absent session
fails loudly and immediately - a command says it is not connected.
A session left
behind on the tenant you switched away from SUCCEEDS, and returns correct-looking
data from the wrong tenant.
Get-EXOMailbox against yesterday's Exchange connection
does not complain.
The Aligned column is the whole point of the command.

NOT CONNECTED AND CANNOT TELL ARE DIFFERENT, AND BOTH ARE REPORTED.
A workload whose
module is not loaded cannot have a session in this runspace, and says 'ModuleNotLoaded'
rather than pretending to a clean 'NotConnected'.
A probe that throws says 'Unknown'.
Reporting either as "not connected" would turn "I could not look" into "there is
nothing there", which is the mistake that makes a stale session invisible.

IT NEVER CONNECTS, IMPORTS OR DISCONNECTS ANYTHING.
Probing a workload by importing
its module would change the thing being measured, and auto-connecting on a read is
how a 10-second Exchange sign-in ends up inside an unrelated command.
Only modules
already loaded in this session are asked.

THE GRAPH SDK AND THE WRITE SESSION SHARE Get-MgContext and are told apart by
AuthType: Connect-MsecGraphSdk signs in app-only, Connect-MsecAdmin delegated.
One
Get-MgContext result therefore belongs to exactly one of those two rows, and reading
it as both would report a write session that does not exist.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecContext
```

The core three - Azure, app session, write session - and whether they agree.

### EXAMPLE 2
```
Get-MsecContext -IncludeWorkload | Where-Object Aligned -eq 'DIFFERENT'
```

Every session pointing somewhere other than the current Azure context.
Empty is the
answer you want before running anything that writes.

## PARAMETERS

### -IncludeWorkload
Also probe Exchange, Teams, SharePoint and Purview.
Off by default: those probes call
into other modules, and a couple of them are slow enough to notice.

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

### -List
Show the SAVED contexts instead of the live sessions - what you can switch to, rather
than where you are.
Mirrors Get-AzContext -ListAvailable.

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

### One PSCustomObject per surface, PSTypeName 'MsecContext'.
## NOTES
Read-only, and local: it inspects session state in this process and calls no API.

## RELATED LINKS
