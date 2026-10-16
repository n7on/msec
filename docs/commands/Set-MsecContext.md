---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Set-MsecContext

## SYNOPSIS
Switches the Azure context, the msec app session and - when the context has one - the
write session, together, by name.

## SYNTAX

```
Set-MsecContext [-Name] <String> [-Admin] [-KeepWorkload] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
THE THREE SESSIONS MOVING SEPARATELY IS THE PROBLEM THIS SOLVES.
The Az context, the
app session and the delegated write session each have their own command and their own
idea of which tenant they are on.
Moving one and forgetting another leaves commands
reading one tenant and writing to a different one, which fails silently rather than
loudly.

IT DISCONNECTS WHAT IT CANNOT REALIGN.
Exchange, Teams, SharePoint and Purview sessions
live inside other modules and cannot be re-pointed at a new tenant - only torn down and
built again.
Left alone they KEEP WORKING against the tenant you just left, returning
correct-looking data from the wrong place, which is worse than being disconnected.
Any
that are connected are dropped, and you reconnect the ones you need.
Use -KeepWorkload
to leave them, which is only sensible when the new context is the same tenant.

IT WILL NOT START A WRITE SESSION YOU DID NOT HAVE, unless -Admin is passed.
Signing in
is interactive, and an interactive prompt in the middle of a context switch is a
surprise.
An EXISTING write session is always moved, because leaving it behind is the
dangerous case.

THE ADMIN ACCOUNT IS ASSERTED, NOT CHOSEN.
Connect-MgGraph has no way to pick an
identity - the browser reuses whichever it remembers - so the saved account is passed
to Connect-MsecAdmin, which REFUSES a sign-in that lands on anyone else.
That turns a
wrong-tenant write into an error at the moment it can still be fixed.

A FAILED RECONNECT DOES NOT UNDO THE SWITCH.
The context change is what was asked for
and it stands; losing a session is reported, loudly, and Get-MsecContext will show it.

## EXAMPLES

### EXAMPLE 1
```
Set-MsecContext prod
```

### EXAMPLE 2
```
Set-MsecContext prod -Admin
Get-MsecContext
```

Switch everything including the write session, then confirm all surfaces agree.

## PARAMETERS

### -Name
The saved context to switch to.
Tab-completes.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Admin
Also establish the write session, signing in if there is not one already.
Without it,
an existing write session is moved but a missing one is left missing.

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

### -KeepWorkload
Leave Exchange, Teams, SharePoint and Purview sessions alone.
Only sensible when the
new context is the same tenant - otherwise they go on answering for the old one.

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

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### The context rows after the switch, same shape as Get-MsecContext.
## NOTES

## RELATED LINKS
