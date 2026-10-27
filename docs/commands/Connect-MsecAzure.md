---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecAzure

## SYNOPSIS
Signs in to the Azure plane as YOU, for the commands that read ARM rather than Graph.

## SYNTAX

```
Connect-MsecAzure [[-Subscription] <String>] [[-TenantId] <String>] [[-Environment] <String>]
 [[-Scope] <String>] [[-MaxContextPopulation] <Int32>] [-UseDeviceCode] [-PassThru] [<CommonParameters>]
```

## DESCRIPTION
The module has three ways in and this is the third.
Connect-Msec reads as the
application, Connect-MsecAdmin writes as you through Graph, and the Azure-plane
commands - Search-MsecLogAnalytics, Get-MsecAzureSecureScore, Get-MsecKeyVaultCertificate
and the rest - run on the Az context, which is neither.
Until now they told you to go
and run Connect-AzAccount, a cmdlet whose defaults disagree with this module's.

IT DEFAULTS TO -Scope Process, WHERE Connect-AzAccount DEFAULTS TO CurrentUser.
That is
the whole reason this exists.
Az's context autosave writes the active context to
~/.Azure/AzureRmContext.json, so a sign-in in one shell silently becomes the default
for every shell you open afterwards - you discover it later, in a different window,
pointed at a tenant you do not remember choosing.
Here the sign-in belongs to the shell
that did it, and -Scope CurrentUser is how you ask for the old behaviour.

THE CREDENTIAL IS SHARED WHATEVER THE SCOPE, and -Scope does not change that.
The token
goes into the OS credential store - on macOS the keychain, under the service name
Microsoft.Developer.IdentityService - which is per user, not per process.
What -Scope
controls is the POINTER: which tenant and subscription a shell is aimed at.
That is the
part that decides where a command lands, and the part worth keeping local.

ON macOS THE BROKER BREAKS INTERACTIVE SIGN-IN, and the error does not say so.
Az 5.x
enables the WAM broker by default (EnableLoginByWam), and it must run on the main
thread, which the PowerShell host does not give it.
The failure reads
"InteractiveBrowserCredential authentication failed: Interactive requests with mac
broker enabled must be executed on the main thread on macOS" and nothing about it
suggests a configuration setting is at fault.
A sign-in that fails this way is caught
here and re-thrown naming the fix, and -UseDeviceCode gets you in meanwhile.

A SOVEREIGN CLOUD IS SLOW, AND THE SLOW PART IS AFTER THE BROWSER.
Measured on one
machine: ~0.08 s per ARM round trip on AzureCloud against ~2.3 s on AzureChinaCloud.
The sign-in itself is quick; what follows is Az building a context per subscription it
can see, 25 of them by default, each a round trip.
Use -MaxContextPopulation to cut it,
and -Verbose to see where the time actually went.

A SOVEREIGN CLOUD NEEDS -Environment AND FAILS OPAQUELY WITHOUT IT.
Azure requires a
separate sign-in per cloud; an account in one cannot see a tenant in another.
Sent to
the wrong authority the sign-in is refused before any prompt, with no mention of the
cloud.

## EXAMPLES

### EXAMPLE 1
```
Connect-MsecAzure -Subscription 'PROD'
```

Signs in for this shell only.
Open another terminal and it is still pointed wherever it
was - which is the point.

### EXAMPLE 2
```
Connect-MsecAzure -Environment AzureChinaCloud -UseDeviceCode
```

A sovereign tenant from a Mac, avoiding both traps at once.

## PARAMETERS

### -Subscription
Subscription to select once signed in, by name or id.
Without it you get whatever Azure
considers your default, which on an account with many subscriptions is rarely the one
you meant.

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

### -TenantId
Tenant to sign in to.
Needed when your account exists in more than one.

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

### -Environment
The Azure cloud: AzureCloud (default), AzureChinaCloud, AzureUSGovernment.
Required for
a sovereign tenant - see the description.

Tab-completes from Get-AzEnvironment, so a cloud registered locally with
Add-AzEnvironment shows up too.
Deliberately NOT a ValidateSet, which would refuse an
air-gapped or national cloud that genuinely exists.

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

### -Scope
Where the sign-in lives.
'Process' (default) keeps it in this shell.
'CurrentUser'
writes it to the shared Az profile, making it the default for every new shell, which is
Connect-AzAccount's own default.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: Process
Accept pipeline input: False
Accept wildcard characters: False
```

### -MaxContextPopulation
How many subscriptions Az builds a context for after sign-in.
Az's own default is 25,
and each one costs a round trip - which is why a sovereign sign-in can sit for a long
time after you have already picked the account in the browser.
Measured: ~0.08 s per
ARM round trip on AzureCloud against ~2.3 s on AzureChinaCloud.

Lower it when you only want one subscription; -1 populates all.
It is NOT lowered by
default, because those populated contexts are what lets Set-MsecContext move between
clouds without a fresh sign-in.

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

### -UseDeviceCode
Sign in with a device code instead of a browser.
The way past the macOS broker failure,
and the way in from a session with no browser at all.

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

### -PassThru
Emit the full Az context as well as the summary.

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

### One PSCustomObject describing the session, PSTypeName 'MsecAzureConnection'.
## NOTES
Signs in as YOU, not as the msec application - this is ARM, and the app holds Graph
permissions, not Azure RBAC.
What you can read is what your own role assignments allow.

## RELATED LINKS
