---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecMySqlConfiguration

## SYNOPSIS
One row per MySQL flexible server per server parameter - the value, the default, and
whether a person set it or the platform did.

## SYNTAX

```
Get-MsecMySqlConfiguration [[-ServerName] <String>] [[-Name] <String[]>] [-UserOverride]
 [[-SubscriptionId] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
RESOURCE GRAPH CANNOT SEE SERVER PARAMETERS AT ALL, which is the whole reason this
command exists.
flexibleServers/configurations, /firewallRules and /databases each
return ZERO rows from the Resources table - re-verified against 12 live servers - and
the parent server row carries no parameter data either.
So the posture questions that
matter most about a database engine, "is TLS required" and "which protocol versions are
accepted", are invisible to Search-MsecAzureResourceGraph and to every .kql in
kql/Graph.
They need a per-server ARM call, and that is what this does.

SOURCE SAYS WHETHER SOMEONE CHANGED IT.
COMPARING VALUE TO DEFAULTVALUE DOES NOT, AND
IS WRONG IN BOTH DIRECTIONS.
Azure reports 'user-override' or 'system-default' per
parameter, and that is the authoritative signal.
Measured on one production server:
require_secure_transport has Value 'ON' and DefaultValue 'ON' - identical - and Source
'user-override', because somebody set it explicitly.
A report built on Value -ne
DefaultValue would not list it, and would therefore miss the server where the same
parameter was deliberately turned OFF for the same reason.
21 of 438 parameters on that
server were user-overrides.
Measured across one estate: 5,230 parameters over 12
servers, of which 147 were user-overrides - under 3%.
That short list is the one worth
reading, and it is how two production servers were found accepting unencrypted
connections.
Use -UserOverride, or filter on IsUserOverride.

ISREADONLY ARRIVES AS THE STRING 'False', AND \[bool\] 'False' IS $true IN POWERSHELL.
Every boolean on this endpoint is a string, so casting instead of comparing turns every
read-only parameter into a settable one and vice versa - silently, with no error
anywhere.
They are parsed by string comparison here and surfaced as real booleans, so
callers never have to know.
162 of 438 parameters are read-only on a current server:
binlog_encryption and innodb_redo_log_encrypt among them, which is why "we could just
turn on binlog encryption" is not an option on this platform.

VALUE IS WHAT WILL APPLY; CURRENTVALUE IS WHAT IS RUNNING.
They differ when a change is
waiting for a restart, and PendingRestart says so.
Reporting Value alone would claim a
setting is in force when the engine has not picked it up yet - for a control like
require_secure_transport that is the difference between protected and not.

RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP.
These are Azure resources, so this
reads through ARM on your Az context like Get-MsecSentinelRule.
The app certificate
holds Graph permissions, not Azure RBAC.

ONE ARM CALL PER SERVER, each returning every parameter - 438 on MySQL 8.4, 392 on 5.7,
5,230 rows across a 12-server estate.
-Name filters client-side because the API has no parameter-name filter, so narrowing by
name saves nothing; narrowing by -ServerName does.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecMySqlConfiguration -UserOverride |
    Format-Table ServerName, Parameter, Value, DefaultValue
```

Everything a person has deliberately changed, across the estate.
The short list worth
reading - 21 of 438 parameters on a typical server.

### EXAMPLE 2
```
# The control that matters, and the servers that do not have it.
Get-MsecMySqlConfiguration -Name require_secure_transport |
    Where-Object Value -ne 'ON'
```

### EXAMPLE 3
```
Get-MsecMySqlConfiguration -Name 'tls_version','*encrypt*' |
    Format-Table ServerName, Parameter, Value, IsReadOnly
```

Transport and at-rest settings together.
IsReadOnly tells you which of them you could
actually change.

## PARAMETERS

### -ServerName
Only servers whose name matches this wildcard pattern, e.g.
'contoso-*'.

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

### -Name
Only parameters matching these wildcard patterns, e.g.
'tls_*', '*encrypt*'.
Filtered
client-side - every parameter is fetched regardless.

AN UNMATCHED NAME RETURNS NOTHING RATHER THAN FAILING, and a pattern that matched
nothing is WARNED about by name, because an empty result from a typo looks exactly
like an empty result from a clean estate.
Server PROPERTIES are not parameters: the
engine version, location and state come from
Search-MsecAzureResourceGraph -ResourceType MySQL, not from here.
A work item shipped
with '-Name version' as its reproduce command on that misunderstanding; it returns no
rows, and silence reads as "no problem found".

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

### -UserOverride
Only parameters someone has set explicitly - Source 'user-override'.
This is the
deviation report, and it is NOT the same as Value -ne DefaultValue; see the
description.

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

### -SubscriptionId
Limit discovery to these subscriptions.
Defaults to every subscription in reach.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per server per parameter, PSTypeName 'MsecMySqlConfiguration'.
## NOTES
Read-only.
Needs Reader on the servers through your Az context - not a Graph permission.
A server whose parameters cannot be read is WARNED about and omitted, never reported as
having none.

## RELATED LINKS
