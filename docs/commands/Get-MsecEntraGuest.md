---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraGuest

## SYNOPSIS
Guest accounts, whether each one was ever redeemed, and when it was last actually
used - the identities in the directory that belong to someone outside the tenant.

## SYNTAX

```
Get-MsecEntraGuest [-PendingOnly] [-NeverSignedIn] [[-InactiveDays] <Int32>] [[-Domain] <String>] [<CommonParameters>]
```

## DESCRIPTION
A guest is a real account in the directory.
It can be added to groups, granted access
to sites and teams, and consented to apps, and it is governed by whatever Conditional
Access covers guests - which in many tenants is less than covers members.
The two
questions worth asking are whether anyone is behind it and whether anyone still uses
it, and neither is on the user object in a form you can read directly.

AN INVITATION IS NOT AN ACCOUNT SOMEONE USES.
InvitationState 'PendingAcceptance'
means the account exists and the invitation was never redeemed - nobody has ever
signed in as it, yet it can already hold group membership and permissions granted in
anticipation.
Measured on one tenant: 107 of 222 guests, 48%, had never redeemed.
Those are not users; they are access waiting for someone who never arrived.

'NEVER SIGNED IN' MUST NOT BE READ OFF lastSignInDateTime, WHICH IS INTERACTIVE ONLY.
An account signing in daily through refresh tokens or a service integration leaves
that field EMPTY while lastNonInteractiveSignInDateTime moves every day.
Taking the
interactive field alone reports an account in active use as dormant - measured on the
same tenant, 111 guests looked dormant that way and 109 genuinely were, so two
actively-signing-in accounts would have been proposed for deletion.
LastSignInUtc here
is the LATEST of the interactive, non-interactive and last-successful timestamps, and
LastSignInKind says which one it came from.

A TENANT WHERE NO GUEST HAS SIGN-IN DATA IS A PERMISSION PROBLEM, NOT AN IDLE TENANT.
Graph omits signInActivity entirely - silently, with no error and no property - when
the caller lacks 'AuditLog.Read.All'.
Every guest then looks like it has never signed
in, which is the single most dangerous way this command could be wrong: it reads as a
list of accounts safe to delete.
So when not one guest carries sign-in data the
command WARNS, and SignInDataAvailable is false on every row.

Runs as the msec app.
Needs 'User.Read.All' for the accounts and 'AuditLog.Read.All'
for the sign-in half; without the latter the account half still works.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraGuest | Format-Table DisplayName, InvitationState, LastSignInUtc, Domain
```

### EXAMPLE 2
```
# Invitations nobody ever redeemed - access granted to an absent person.
Get-MsecEntraGuest -PendingOnly
```

### EXAMPLE 3
```
# Redeemed once, then abandoned. The deletion candidates that are NOT merely pending.
Get-MsecEntraGuest -InactiveDays 180
```

### EXAMPLE 4
```
# Which organisations hold accounts here, largest first.
Get-MsecEntraGuest | Group-Object Domain | Sort-Object Count -Descending
```

## PARAMETERS

### -PendingOnly
Only guests whose invitation was never redeemed.

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

### -NeverSignedIn
Only guests with no sign-in of any kind.
Counts non-interactive activity, so an
account used by an integration is not included.

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

### -InactiveDays
Only guests whose last sign-in is older than this many days.
Guests that have never
signed in at all are NOT returned - that is -NeverSignedIn, and conflating the two
hides which of the pair you are looking at.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 0
Accept pipeline input: False
Accept wildcard characters: False
```

### -Domain
Only guests whose mail address is in this domain, e.g.
'contoso.com'.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per guest, PSTypeName 'MsecEntraGuest'.
## NOTES
Read-only.
Deleting a guest removes its access everywhere at once, which is the point
and also the risk: check group membership with Get-MsecEntraGroupMember first, since a
guest can be the only external member of something that matters.

## RELATED LINKS
