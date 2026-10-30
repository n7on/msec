---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSharePointSiteSharing

## SYNOPSIS
Each site's external sharing level and its own domain allow-list - the two settings
that decide whether an external share succeeds.

## SYNTAX

```
Get-MsecSharePointSiteSharing [[-Url] <String>] [-IncludeDomainRestriction] [-RestrictedOnly] [<CommonParameters>]
```

## DESCRIPTION
SEPARATE FROM Get-MsecSharePointSite BECAUSE IT RUNS AS A DIFFERENT IDENTITY.
That one
reads the inventory as the msec app; this one cannot.
Tenant administration needs
Sites.FullControl.All - write access to every site - which this module deliberately
does not hold.
Verified rather than assumed: the app certificate authenticates against
the -admin host and then fails every admin call with "Attempted to perform an
unauthorized operation".

SO IT SIGNS IN AS YOU, through Connect-MsecSharePointOnline -Interactive.
The
capability comes from your own SharePoint Administrator role; the app gains nothing.
The same bargain Connect-MsecAdmin makes, and unrelated to the Az context - an
Az-derived token is refused by SharePoint whatever the account, because its audience is
normalised to the service principal's GUID.

THE TWO VALUES COST VERY DIFFERENT AMOUNTS, which is why the domain list is opt-in.
The
sharing level comes from ONE call for the whole tenant - measured, 144 sites in about a
second.
The domain list cannot: see below.

THE BULK CALL LIES ABOUT THE DOMAIN RESTRICTION.
Get-PnPTenantSite with no -Identity
returns SharingDomainRestrictionMode as "None" and an empty domain list for a site that
genuinely has one.
Measured on the same site: bulk said None, -Identity said AllowList
with four domains.
A report built on the bulk value would state confidently that no
site in the tenant restricts by domain, and that is exactly the kind of wrong answer
nobody re-checks.
-IncludeDomainRestriction therefore queries each site individually,
about 0.4s each, and leaves DomainRestriction $null rather than "None" where a site
could not be read.

THE TWO LISTS INTERSECT, THEY DO NOT ADD.
A site's domain list is combined with the
tenant's from Get-MsecSharePointTenantSetting: a site can be stricter but never
broader.
Measured on one investigation, the tenant allowed one domain and the site
allowed three different ones, so the effective set was EMPTY and every external share
from that site failed - while each list read as perfectly reasonable on its own.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecSharePointSiteSharing | Group-Object SharingLevel
```

The estate at a glance.
On one tenant: 95 ExternalUserSharingOnly, 27
ExistingExternalUserSharingOnly, 21 Disabled, and a single
ExternalUserAndGuestSharing - which is the most permissive site in the tenant and worth
knowing by name.

### EXAMPLE 2
```
Get-MsecSharePointSiteSharing -IncludeDomainRestriction |
    Where-Object { $_.DomainRestriction -eq 'AllowList' }
```

The sites carrying their own domain list.
Each one overrides the tenant's by
intersection, so a stale list here is invisible until a share fails.

## PARAMETERS

### -Url
A single site collection.
Without it, every site the admin API lists is returned.

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

### -IncludeDomainRestriction
Also fetch each site's domain allow/block list.
ONE CALL PER SITE - see the
description.
About 0.4s each; roughly a minute for 150 sites.

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

### -RestrictedOnly
Only sites that are not wide open: anything whose sharing level is not
ExternalUserAndGuestSharing, or that carries a domain restriction.
Applied after the
reads, so it narrows the output rather than the work.

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

### One PSCustomObject per site, PSTypeName 'MsecSharePointSiteSharing'.
## NOTES
Needs Connect-MsecSharePointOnline -Interactive against the tenant's -admin host, and
SharePoint Administrator on YOUR account.
Runs as you, not as the msec app, and the
app is deliberately not able to do this.

## RELATED LINKS
