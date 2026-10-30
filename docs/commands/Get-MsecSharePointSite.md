---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecSharePointSite

## SYNOPSIS
Every SharePoint site in the tenant, classified - the inventory to run a site access
review against.

## SYNTAX

```
Get-MsecSharePointSite [-IncludeAppContainer] [-IncludePersonal] [-All] [-IncludeSettings]
 [[-CreatedSince] <DateTime>] [-IncludeSharingLevel] [-IncludeDomainRestriction] [<CommonParameters>]
```

## DESCRIPTION
TWO SHARING SETTINGS DECIDE WHETHER AN EXTERNAL SHARE SUCCEEDS, and both need the
TENANT ADMIN host.
A site carries its own sharing level - "Only people in your
organization" through "Anyone" - and its own domain allow-list, independent of the
tenant settings Get-MsecSharePointTenantSetting reports.
They combine with the tenant's
as an INTERSECTION, so a site can be stricter but never broader, and two lists that
disagree leave a site unable to share with anybody.
Measured on one investigation: the
tenant allowed one domain, the site allowed three different ones, the intersection was
empty, and every external share failed with a domain error.

THE APP CANNOT READ THEM, AND IS NOT GOING TO BE ABLE TO.
Tenant administration needs
Sites.FullControl.All - write access to every site - which this module deliberately
does not hold.
Verified: the certificate authenticates against the -admin host and then
fails every admin call with "Attempted to perform an unauthorized operation".
So
-IncludeSharingLevel requires an INTERACTIVE sign-in as somebody holding SharePoint
Administrator, through Connect-MsecSharePointOnline -Interactive.
The capability comes
from that person's role; the app gains nothing.

THE BULK CALL LIES ABOUT THE DOMAIN RESTRICTION, which is why reading it is a separate
switch.
Get-PnPTenantSite with no -Identity returns every site in about a second and
its SharingCapability is correct - but SharingDomainRestrictionMode comes back as
"None" and the domain list empty for a site that genuinely has one.
Measured on the
same site: bulk said None, -Identity said AllowList with four domains.
A report built
on the bulk result would state confidently that no site restricts by domain.
-IncludeDomainRestriction therefore queries each site individually - about 0.4s each,
a minute for 150 sites - and leaves the value $null rather than "None" when a site
could not be read.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecSharePointSite
```

### EXAMPLE 2
```
# The access review: every real site, and who owns it.
Get-MsecSharePointSite | ForEach-Object {
    Get-MsecSharePointSiteUser -Url $_.WebUrl
}
```

### EXAMPLE 3
```
# What the tenant actually holds, before deciding what to review.
Get-MsecSharePointSite -All | Group-Object SiteType | Sort-Object Count -Descending
```

## PARAMETERS

### -IncludeAppContainer
Include Loop and other app-created storage containers.

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

### -IncludePersonal
Include OneDrive personal sites.
Note these do not appear in the search Graph uses here
anyway on most tenants; the switch exists so the exclusion is explicit rather than
accidental.

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

### -All
Include everything, classified but unfiltered.

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

### -IncludeSettings
Fetch each site's own properties - sharing-link policy, sensitivity label, restricted
access control, lock state.
ONE EXTRA REQUEST PER SITE, which is why it is opt-in;
measured on one tenant, 149 sites.

IT DOES NOT INCLUDE THE SITE'S SHARING LEVEL OR ITS DOMAIN LIST, and reading it as
though it did is the mistake this paragraph exists to prevent - see the description.
Settings is $null when the site could not be read, never a blank object.

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

### -CreatedSince
Only sites created on or after this date.

THE POINT IS A WORKLIST, NOT AN ANSWER.
Self-service site creation means new sites
arrive with the tenant's default sharing level and no review; this narrows 149 sites to
the few worth checking - measured, 10 in 180 days.
The sharing level itself still has
to be read in the SharePoint admin centre, for the reason in the description.

FILTERS ON CREATION, NOT LAST MODIFIED.
"What appeared recently" and "what changed
recently" are different questions and this answers the first.
A site with no
createdDateTime is included and warned about rather than dropped, because absent is not
the same as old.

```yaml
Type: DateTime
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeSharingLevel
The site's external sharing level, from the tenant admin API: Disabled,
ExistingExternalUserSharingOnly, ExternalUserSharingOnly or ExternalUserAndGuestSharing.

REQUIRES AN INTERACTIVE ADMIN SESSION - see the description - and throws naming how to
get one rather than returning a quietly empty column.
One bulk call for the whole
tenant, so it is cheap.
SharingLevel is $null for anything the admin API does not list,
such as a subsite.

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

### -IncludeDomainRestriction
The site's own domain allow/block list.
Implies -IncludeSharingLevel.

ONE CALL PER SITE, because the bulk result is wrong for this field - see the
description.
About 0.4s per site; roughly a minute for 150.
DomainRestriction is $null
when a site could not be read, never "None", because "None" is exactly the wrong answer
the cheap path gives.

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

### PSCustomObject per site, PSTypeName 'MsecSharePointSite'.
## NOTES
THREE IDENTITIES, DEPENDING ON WHAT YOU ASK FOR, and it is worth knowing which answered
which column:

  the site list            the msec app, on Microsoft Graph
  -IncludeSettings         the msec app, on SharePoint (each site's own host)
  -IncludeSharingLevel     YOU, through an interactive PnP sign-in to the admin host
  -IncludeDomainRestriction

The first two need Connect-Msec and Sites.Read.All on MICROSOFT GRAPH - a different
permission from the identically-named one on the SharePoint service principal.
Both are
granted by New-MsecApp -Workload SharePoint and do different jobs: the Graph one
enumerates sites, the SharePoint one reads what is inside them.

The last two need Connect-MsecSharePointOnline -Interactive and a SharePoint
Administrator role on YOUR account.
They are not app-readable at any permission this
module is willing to hold - see the description.
The interactive sign-in is PnP's own
and has nothing to do with the Az context: an Az-derived token is refused by SharePoint
whatever the account, because its audience is normalised to the service GUID.

## RELATED LINKS
