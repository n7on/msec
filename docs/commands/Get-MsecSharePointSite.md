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
 [[-CreatedSince] <DateTime>] [<CommonParameters>]
```

## DESCRIPTION
THE SITE INVENTORY, AS THE APP.
What this does NOT carry is the pair of settings that
actually decide whether an external share succeeds - the site's own sharing level and
its own domain allow-list.
Those are tenant-admin properties, unreadable at any
permission this module is willing to hold, and they live in
Get-MsecSharePointSiteSharing, which signs in as a human instead.

SO A PERMISSIVE READING HERE SETTLES NOTHING ABOUT SHARING.
Site settings combine with
the tenant's as an INTERSECTION - a site can be stricter but never broader - and two
lists that disagree leave a site unable to share with anybody.
Measured on one
investigation: the tenant allowed one domain, the site allowed three different ones,
the intersection was empty, and every external share failed with a domain error while
every value available here read as permissive.

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

IT DOES NOT INCLUDE THE SITE'S SHARING LEVEL OR ITS DOMAIN LIST - those are in
Get-MsecSharePointSiteSharing, and reading these as though they answered the same
question is the mistake this paragraph exists to prevent.
ShareByEmailEnabled in
particular is NOT the sharing mode: measured, it was True on a site where external
sharing was completely blocked.
Settings is $null when a site could not be read, never
a blank object.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per site, PSTypeName 'MsecSharePointSite'.
## NOTES
Runs as the msec app throughout - both the site list and -IncludeSettings.
Needs
Connect-Msec and Sites.Read.All on MICROSOFT GRAPH, which is a different permission
from the identically-named one on the SharePoint service principal.
Both are granted by
New-MsecApp -Workload SharePoint and do different jobs: the Graph one enumerates sites,
the SharePoint one reads what is inside them.

Get-MsecSharePointSiteSharing is the one that needs a human.

## RELATED LINKS
