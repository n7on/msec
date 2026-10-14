---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecBusinessCentralEnvironment

## SYNOPSIS
Dynamics 365 Business Central environments - production and sandbox - with how many
companies and users each one carries.

## SYNTAX

```
Get-MsecBusinessCentralEnvironment [-Quick] [-SandboxOnly]
 [<CommonParameters>]
```

## DESCRIPTION
A SANDBOX IS NOT A LOWER-SENSITIVITY ENVIRONMENT, which is the reason this command
exists.
A Business Central sandbox is routinely created by copying production, so it can
hold the same financial data, and it carries its OWN user list and its OWN permission
assignments - granted separately, reviewed separately, and usually reviewed less.
An
access review that covers production and stops there has covered a fraction of the
estate.
Measured on one tenant: two production environments and three sandboxes, with
the sandboxes holding 33, 37 and 45 users.

THE COMMAND DOES NOT CLAIM TO DETECT A PRODUCTION COPY.
The admin API exposes no field
saying where a sandbox came from, so inferring it from a name containing 'COPY' would be
a guess dressed as a measurement.
Type, company count and user count are reported and
the judgement is left to the reader - a sandbox with as many companies as production is
worth a question whatever it is called.

COUNTS COST A REQUEST EACH, so -Quick skips them when the environment list alone is
wanted.
A count that could not be read is $null rather than 0: an environment nobody
could enumerate must not render as an empty one.

Runs as the signed-in user - see the note below.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecBusinessCentralEnvironment
```

Every environment with its company and user counts.

### EXAMPLE 2
```
Get-MsecBusinessCentralEnvironment -SandboxOnly
```

The environments most likely to hold production data under least scrutiny.

### EXAMPLE 3
```
Get-MsecBusinessCentralEnvironment | Where-Object { $_.Type -ne 'Production' -and $_.Users -gt 20 }
```

Non-production environments with a real user population behind them.

## PARAMETERS

### -Quick
Environment list only.
Skips the per-environment company and user counts.

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

### -SandboxOnly
Only non-production environments.

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

### PSCustomObject per environment, PSTypeName 'MsecBusinessCentralEnvironment'.
## NOTES
RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP.
Business Central offers only
API.ReadWrite.All and Automation.ReadWrite.All as application permissions - there is no
read-only variant - so granting one to the msec app would let the Key Vault certificate
write to a finance system.
A delegated token carries your own Business Central
permissions and grants nothing new.
Same pattern as Get-MsecPowerPlatformEnvironment.

Needs Connect-AzAccount, not Connect-Msec.

## RELATED LINKS
