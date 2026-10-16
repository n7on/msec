---
external help file: Msec-help.xml
Module Name: Msec
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

THE SESSION OUTLIVES THE SHELL BY DEFAULT, THE SAME WAY Connect-Msec DOES.
Its
read session persists because a tenant profile lets any later session re-authenticate
with the Key Vault certificate; this one persists because -ContextScope CurrentUser
caches a refresh token.
Connect-MgGraph's own default is Process scope, which left the
two commands behaving differently - the read session available everywhere, the write
session only inside the shell that signed in, with an empty MSAL cache file on disk as
the only clue.

THAT PERSISTENCE IS A REAL WIDENING, not a convenience.
Until the token expires or you
run Disconnect-MgGraph, any process running as you can obtain a delegated token
carrying your write scopes, with no prompt and nobody watching.
The module's position
is still that writes belong to a person - that is why they are delegated rather than
application permissions, and why every change is attributable to a named account - but
"a person signed in once on this machine" is a weaker claim than "a person is at the
keyboard now".
Use -ContextScope Process where that distinction matters, and
Disconnect-MgGraph when you are done.

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
'CurrentUser' (default) caches a refresh token so other
sessions - and other processes running as you - can write.
'Process' keeps it in this
shell only, which is Connect-MgGraph's own default.

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
