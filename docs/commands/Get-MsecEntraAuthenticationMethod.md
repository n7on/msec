---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraAuthenticationMethod

## SYNOPSIS
Which authentication methods the tenant permits, who they are available to, and which of
them are phishing-resistant - what "require MFA" actually means here.

## SYNTAX

```
Get-MsecEntraAuthenticationMethod [-EnabledOnly] [-PhishableOnly]
 [<CommonParameters>]
```

## DESCRIPTION
Every MFA requirement in the tenant - Conditional Access, PIM activation, step-up on a
privileged role - resolves to "satisfy one of the enabled methods".
This says what that
set is.
A tenant can require MFA everywhere and still accept a code sent by email.

STATE ALONE IS MISLEADING AND THIS IS THE COMMAND'S MAIN POINT.
A method reads 'enabled'
while being scoped to a single group, so it is enabled for the tenant and available to
almost nobody.
Measured on one tenant: Fido2 showed state 'enabled' with includeTargets
of exactly one group - the emergency-access accounts, two people - while SMS, Voice and
Email were enabled for all users.
Reporting the state column alone would have described
that tenant as having FIDO2.

AvailableToAllUsers is therefore the column to read: true only when the method is enabled
AND includes the built-in 'all_users' target.
IncludeTarget and ExcludeTarget carry the
detail, resolved to group names.

NOT EVERY ENABLED METHOD CAN SATISFY MFA.
Email OTP is usable for B2B guest redemption
and self-service password reset, not as a second factor for a member account; QR code
PIN and Temporary Access Pass are onboarding and recovery credentials.
The command
reports what the tenant permits, which is a wider set than what satisfies an MFA grant.
Treat -PhishableOnly as "enabled and not phishing-resistant", not as "will satisfy a
Conditional Access MFA control".

PHISHING RESISTANCE IS MICROSOFT'S CLASSIFICATION, NOT A JUDGEMENT MADE HERE.
Microsoft
documents FIDO2/passkeys, Windows Hello for Business and certificate-based
authentication as phishing-resistant; everything else - SMS, voice, email, software OATH
and Authenticator push - is not.
IsPhishingResistant reports that mapping and nothing
more.
A false there is not an accusation that the method is broken; it means a
credential-phishing or SIM-swap attack can satisfy it.

A DISABLED METHOD IS STILL RETURNED, with State 'disabled'.
Dropping it would make "we
considered this and turned it off" indistinguishable from "this does not exist", and the
disabled list is where TemporaryAccessPass and X509Certificate live - the two a tenant
hardening its privileged access usually wants to turn ON.

WINDOWS HELLO FOR BUSINESS IS NOT IN THIS POLICY AND SO IS NOT RETURNED.
It is governed
by device configuration (Intune/group policy), not by the authentication methods policy,
so the Graph response has no row for it at all.
It is also phishing-resistant and, on
the tenant this was built against, the most widely held strong credential there is - 118
registrations.
Reading this command's output as the complete list of phishing-resistant
coverage would therefore understate it badly.
Pair it with
Get-MsecEntraMfaRegistration, which reports what users have actually registered.

A SCOPED METHOD DOES NOT REVOKE EXISTING REGISTRATIONS.
Targeting controls who may
REGISTER a method, not who may use one already held.
On the same tenant Fido2 was scoped
to the break-glass group while 13 users held synced passkeys and 16 held macOS secure
enclave keys - registered before the scope narrowed, and still usable.
So a narrow
IncludeTarget means "no new enrolments", not "nobody has this".

Runs as the msec app.
Needs 'Policy.Read.All', which the app already holds.
Group names
are resolved with Group.Read.All; where a group cannot be resolved its id is reported
rather than a blank, because an unnamed target is still a target.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraAuthenticationMethod
```

Every method, its state, who it reaches, and whether it resists phishing.

### EXAMPLE 2
```
Get-MsecEntraAuthenticationMethod -PhishableOnly
```

What "require MFA" can actually be satisfied with by someone who has phished a password.

### EXAMPLE 3
```
Get-MsecEntraAuthenticationMethod | Where-Object { $_.State -eq 'enabled' -and -not $_.AvailableToAllUsers }
```

Methods that are on, but reach only a named group - often a pilot that never widened.

## PARAMETERS

### -EnabledOnly
Only methods currently enabled.

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

### -PhishableOnly
Only enabled methods that are NOT phishing-resistant.
Note this is "enabled and not
phishing-resistant", not "satisfies an MFA grant" - see the description on Email OTP.

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

### PSCustomObject per method, PSTypeName 'MsecEntraAuthenticationMethod'.
## NOTES
Read-only.
Read alongside Get-MsecEntraConditionalAccessPolicy and
Get-MsecEntraPimPolicy: those say where MFA is demanded, this says what will satisfy it.

## RELATED LINKS
