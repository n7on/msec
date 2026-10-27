---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecAdmin

## SYNOPSIS
Signs in AS YOU, with delegated write scopes, for the commands that change something.
Read commands keep using the app; this session is only for writes.

## SYNTAX

```
Connect-MsecAdmin [[-Scope] <String[]>] [[-TenantId] <String>] [[-Account] <String>] [[-ContextScope] <String>]
 [-PassThru] [<CommonParameters>]
```

## DESCRIPTION
THE APP CANNOT DO THIS, ON PURPOSE.
Every Graph permission New-MsecApp consents is
*.Read.All, so the certificate in Key Vault cannot change anything - that is the
module's central promise and it is enforced by the token, not by naming.
Writes
therefore run as a person instead: attributable to a named account, subject to your
Conditional Access and MFA, bounded by your own Defender RBAC rather than tenant-wide
application permissions, and impossible from an unattended pipeline unless somebody
deliberately sets one up.

NOT THE -AsCurrentUser PATTERN, AND HERE IS WHY.
Connect-MsecTeams borrows the Az
context's token, which works because Azure PowerShell's first-party app holds the
scopes those commands need.
Measured on a live tenant, its Graph token carries
Application.ReadWrite.All, Group.ReadWrite.All, Directory.AccessAsUser.All and
User.Read.All - and nothing for security.
There is no SecurityAlert.ReadWrite.All in
it, so borrowing cannot resolve an alert.
This asks for consent properly instead.

CONSENT REQUESTED IS NOT CONSENT GRANTED.
Connect-MgGraph succeeds when a tenant
declines a scope; the context simply comes back without it, and the first write then
fails with a 403 that names nothing.
Every requested scope is checked against what was
actually granted, and a missing one is reported by name here rather than discovered
later.

THE SESSION PERSISTS, SO IT CAN BE REUSED.
-ContextScope defaults to CurrentUser,
which caches a refresh token, so signing in once covers later shells and later
switches instead of opening a browser each time.
A named context exists to collect
connections and reuse the ones already authenticated; a write session that evaporated
with the shell could never be part of that.

PERSISTING THE CREDENTIAL IS NOT THE SAME AS SHARING THE POINTER, and conflating the
two is the mistake worth avoiding here.
The cached token says "this person has signed
in on this machine".
It does NOT decide which tenant any given shell is aimed at -
Get-MgContext is per process, and this command always names the tenant and the account
explicitly, so two shells can hold write sessions in two different tenants at the same
time and neither can re-point the other.
The thing that genuinely did leak between
shells was the AZURE context pointer, which Set-MsecContext and Connect-MsecAzure keep
process-scoped for exactly that reason.

WHAT IT DOES COST: until the token expires or you run Disconnect-MgGraph, any process
running as you can obtain a delegated token carrying your write scopes, with no prompt.
The module's position is still that writes belong to a person - that is why they are
delegated rather than application permissions, and why every change is attributable to
a named account - but "somebody signed in on this machine" is a weaker claim than "a
person is at the keyboard now".
-ContextScope Process declines the trade, at the price
of signing in again on every switch.

IT SIGNS IN TO THE CLOUD Connect-Msec IS READING, not always the commercial one.
Connect-MgGraph defaults to Global, whose authority is login.microsoftonline.com, and a
sovereign tenant id does not resolve there - against a China tenant the sign-in is
rejected before any consent screen and the only message is
"InteractiveBrowserCredential authentication failed:" with nothing after the colon.
The
cloud is taken from the read session's Graph endpoint, so run Connect-Msec first.
With
no read session the commercial cloud is assumed, which is right for most people and
wrong in exactly the case that is hardest to diagnose.

IT WILL REFUSE A DIFFERENT TENANT FROM THE ONE YOU ARE READING.
If Connect-Msec holds
a session, this must sign in to the same tenant.
Reading one tenant and writing to
another is the kind of mistake that is obvious afterwards and invisible at the time.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec      # reads, as the app
Connect-MsecAdmin                        # writes, as you
```

### EXAMPLE 2
```
# Only what this session needs.
Connect-MsecAdmin -Scope SecurityAlert.ReadWrite.All
```

## PARAMETERS

### -Scope
Delegated scopes to request.
DEFAULTS TO EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED,
so a bare Connect-MsecAdmin makes all of them work and nobody has to know which consent
belongs to which command.
Pass it explicitly for a least-privilege session covering only
what you intend to do.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @(
            'SecurityIncident.ReadWrite.All'
            'SecurityAlert.ReadWrite.All'
            'CustomDetection.ReadWrite.All'
        )
Accept pipeline input: False
Accept wildcard characters: False
```

### -TenantId
Tenant to sign in to.
Defaults to the tenant Connect-Msec is using, which is almost
always what you want.

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

### -Account
The account that must end up signed in.
Cannot select one - Connect-MgGraph has no
such control and the browser reuses whichever identity it remembers - but a sign-in
that lands on a different account is REFUSED and the session closed, rather than
leaving you writing as somebody else.

Without it, a mismatch against the account this tenant used last time is a warning.

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

### -ContextScope
Where the token lives.
'CurrentUser' (default) caches a refresh token so later shells
and later context switches reuse it instead of prompting.
'Process' keeps it in this
shell only - Connect-MgGraph's own default - and then every switch that moves a write
session signs in again.

Neither value decides which tenant a shell is aimed at; see the description.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: CurrentUser
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Emit the Graph context as well as the summary.

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

### One PSCustomObject describing the session: Account, TenantId, GrantedScope.
## NOTES
Needs the Microsoft.Graph.Authentication module, which is NOT a dependency of msec -
it is only required by the write commands.

Disconnect with Disconnect-MgGraph.
Connect-Msec and this session are independent;
disconnecting one leaves the other alone.

## RELATED LINKS
