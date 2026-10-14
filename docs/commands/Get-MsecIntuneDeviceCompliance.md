---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneDeviceCompliance

## SYNOPSIS
Why each device is non-compliant - the policy and the individual setting that failed,
separating devices that break a security control from devices that merely went quiet.

## SYNTAX

```
Get-MsecIntuneDeviceCompliance [-IncludeCompliant] [[-DeviceName] <String>] [-SecurityOnly] [<CommonParameters>]
```

## DESCRIPTION
Get-MsecIntuneDevice reports THAT a device is non-compliant.
The reason lives two
levels below it and nothing surfaces it: the failing policy is on
/managedDevices/{id}/deviceCompliancePolicyStates and the failing SETTING is a further
call per policy.
This command makes that join, one row per device per failing setting.

MOST NON-COMPLIANCE IS NOT A SECURITY FAILURE, AND TREATING IT AS ONE IS THE MISTAKE
THIS COMMAND EXISTS TO PREVENT.
Intune ships a built-in 'Default Device Compliance
Policy' whose rules are housekeeping - has the device checked in recently
(RequireRemainContact), does the owning account still exist (RequireUserExistence), is
any policy assigned at all (RequireDeviceCompliancePolicyAssigned).
A device failing
those is stale, not insecure.
Measured on one tenant: 33 non-compliant devices, 30
attributable failures, and every single one from the default policy - not one device
failed encryption, OS version or any configured baseline.
Category marks each row
'Housekeeping' or 'SecurityControl' so a report can say which it found.

A FAILED READ AND AN EMPTY ONE ARE DIFFERENT, AND BOTH ARE REPORTED.
Intune throttles
this endpoint hard - two calls per device - and Invoke-MsecGraphRequest gives up after
five retries, so on a tenant of any size some devices lose their read to a 429.
Category 'Unreadable' marks those; 'Unattributed' means the call SUCCEEDED and
returned nothing.
Collapsing the two was the original behaviour and it made the output
differ run to run: the same tenant gave 4 unattributed devices on one pass and 9 on
the next, and one of them had three perfectly readable settings when queried alone.
The run also warns when anything was unreadable, because a silently short report is
worse than a slow one.

A DEVICE WHOSE SETTINGS CANNOT BE ATTRIBUTED IS REPORTED, NOT DROPPED.
A device can be
flagged non-compliant while its settingStates return nothing - measured, 4 of 33 - and
omitting those rows would quietly shrink the problem.
They come back with Category
'Unattributed' and a null Setting, because "we could not determine why" and "there is
nothing wrong" must not look the same.

READ settingName, NOT setting.
The 'setting' property is present and EMPTY on every
row the v1.0 endpoint returns; the human-readable rule is in 'settingName'.
Reading
the obvious one yields a column of blanks that looks like missing data.

THIS COSTS TWO GRAPH CALLS PER DEVICE, which is why it defaults to non-compliant
devices only.
A tenant of any size should not pay for the compliant ones to answer a
question about the broken ones; -IncludeCompliant lifts that when the full picture is
actually wanted.

Runs as the msec app.
Needs 'DeviceManagementManagedDevices.Read.All'.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecIntuneDeviceCompliance
```

### EXAMPLE 2
```
# The failures that actually indicate an insecure device.
Get-MsecIntuneDeviceCompliance -SecurityOnly
```

### EXAMPLE 3
```
# What is actually wrong, tenant-wide.
Get-MsecIntuneDeviceCompliance | Group-Object Setting | Sort-Object Count -Descending
```

## PARAMETERS

### -IncludeCompliant
Also evaluate devices that are currently compliant.
Two extra Graph calls per device.

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

### -DeviceName
Only devices whose name matches this wildcard pattern, e.g.
'VIE01*'.

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

### -SecurityOnly
Only failures of a real configured policy - drops the built-in default policy's
housekeeping rules, which is usually what someone means by "non-compliant devices".

ROWS WHOSE REASON COULD NOT BE READ ARE STILL RETURNED, because an unreadable reason
might be a security failure and this is the view someone uses to find those.
Filter
them out explicitly with Where-Object Category -eq 'SecurityControl' if you want only
what is confirmed.

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

### PSCustomObject per device per failing setting, PSTypeName 'MsecIntuneDeviceCompliance'.
## NOTES
Read-only.
A device that has not checked in cannot be remediated by Intune at all -
policy only applies when the device talks to the service - so DaysQuiet is the column
that decides whether a finding is actionable or whether the device simply needs
retiring.

## RELATED LINKS
