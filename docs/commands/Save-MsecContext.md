---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Save-MsecContext

## SYNOPSIS
Remembers the current sessions under a name, so Set-MsecContext can put them all back
together later.

## SYNTAX

```
Save-MsecContext [-Name] <String> [-AdminAccount <String>] [-Force]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
SNAPSHOTS WHAT IS CONNECTED RIGHT NOW, which is why it takes almost no parameters.
Connect everything the way you want it - Azure context, Connect-Msec, and
Connect-MsecAdmin if you write in this tenant - then name it.
Typing the subscription,
vault and admin account again by hand is how they drift apart.

THE ADMIN ACCOUNT IS THE POINT, not an extra.
Connect-MgGraph cannot choose an
identity; the browser reuses whichever it remembers.
With two tenants and two
identities the wrong one is picked silently, and surfaces much later as a write into
the tenant you did not mean, or as AADSTS500213 - a cross-tenant policy error that
names nothing about accounts.
Recording the account here lets Set-MsecContext refuse a
mismatch instead of discovering it afterwards.

NO SECRET IS STORED.
Subscription, tenant, cloud, vault name, client id, certificate
name and a UPN - the same things you would type on a command line.
msec signs with a key that
never leaves Key Vault, so there is nothing here worth having.

Saved at the cache ROOT, not under a tenant folder: a named context exists in order to
pick a tenant, so it cannot be filed under one.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-prod
Connect-MsecAdmin
Save-MsecContext -Name prod
```

The usual flow: get it right once, then name it.

### EXAMPLE 2
```
Get-MsecContext -List
```

What has been saved.

## PARAMETERS

### -Name
What to call it.
Re-saving an existing name overwrites it.

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

### -AdminAccount
The account the write session must use in this context.
Defaults to whatever
Connect-MsecAdmin is currently signed in as, or to nothing if there is no write
session - in which case Set-MsecContext will not try to establish one.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Force
Overwrite an existing context of the same name without asking.

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

### The saved context, PSTypeName 'MsecSavedContext'.
## NOTES

## RELATED LINKS
