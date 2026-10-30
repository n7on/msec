---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecSharePointOnline

## SYNOPSIS
Signs the PnP.PowerShell module in using the msec session's token, so Get-PnP* commands
run as the msec app without its private key leaving Key Vault.

## SYNTAX

```
Connect-MsecSharePointOnline [-Url] <String> [[-MinimumMinutes] <Int32>] [-PassThru] [-Interactive]
 [[-ClientId] <String>] [<CommonParameters>]
```

## DESCRIPTION
Much of SharePoint IS reachable through Graph - /sites, site permissions, the Microsoft
365 group behind a group-connected site - and where that is true, use Graph.
What Graph
does NOT expose is a site's own SharePoint groups: the Owners, Members and Visitors
groups that Get-PnPGroup reads.
Those are a SharePoint concept, they are the actual
permission model for classic (STS#3) sites, and there is no Graph equivalent.
PnP is
the only way to read them.

THE TOKEN IS PER SITE COLLECTION HOST, NOT TENANT-WIDE.
SharePoint issues tokens whose
audience is the hostname - https://contoso.sharepoint.com - so the resource is derived
from -Url rather than fixed.
A token for the tenant host does not work against
contoso-admin.sharepoint.com, which is why connecting to the admin centre needs its own
call.

SharePoint needs Sites.Read.All (or Sites.FullControl.All to write) as an APPLICATION
permission, admin-consented.
Unlike Exchange, no directory role is involved.

THE MODULE IS NOT AN msec DEPENDENCY.
It is imported only when this command is called.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Connect-MsecSharePointOnline -Url https://contoso.sharepoint.com
Get-PnPTenantSite
```

### EXAMPLE 2
```
# Enumerating many sites: one connection per site collection, which is how PnP works.
Connect-MsecSharePointOnline -Url https://contoso.sharepoint.com
Get-PnPTenantSite | ForEach-Object {
    Connect-MsecSharePointOnline -Url $_.Url
    Get-PnPGroup -AssociatedOwnerGroup
}
```

## PARAMETERS

### -Url
The site collection to connect to, e.g.
https://contoso.sharepoint.com/sites/finance,
or the tenant root.
The token's audience is derived from this URL's host.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MinimumMinutes
Fail unless the token has at least this long left.
Default 5.
PnP is handed a static
token and cannot renew it.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 5
Accept pipeline input: False
Accept wildcard characters: False
```

### -PassThru
Return the connection object instead of making it the ambient one, so the caller's
current site is left alone.
Pass the result to any PnP cmdlet's -Connection parameter.
This is how Get-MsecSharePointSiteUser connects on your behalf without moving your
session out from under you.

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

### -Interactive
Sign in as yourself through PnP's browser flow rather than with the app certificate.
Required to reach the tenant admin host, where the app-only path is refused - see the
description.
Needs -ClientId.

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

### -ClientId
The Entra app to sign in with, for -Interactive.
PnP 3.x ships no default app, so this
is not optional.
It must be registered in this tenant and hold the DELEGATED SharePoint
permission AllSites.FullControl.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES
Needs Connect-Msec first, and the PnP.PowerShell module - which is NOT a dependency of
msec.

THE Az SESSION CANNOT BE BORROWED HERE, unlike Connect-MsecTeams.
That API accepts a
token whose audience is the service; SharePoint validates the audience against the HOST
it is presented to, and Get-AzAccessToken -ResourceUrl normalises every sharepoint.com
URL - tenant root and admin host alike - to the service principal's GUID,
00000003-0000-0ff1-ce00-000000000000.
The token is issued, carries user_impersonation,
and is then refused with a bare 401.
Verified against a live tenant on both hosts, and
re-verified since.

-Interactive IS THE WAY IN AS YOURSELF, because PnP does its own sign-in and can
therefore mint a token whose audience is the actual host.
That is what makes the
TENANT ADMIN host reachable - the app-only certificate path authenticates against it
and then fails every admin call with "Attempted to perform an unauthorized operation",
because tenant administration needs Sites.FullControl.All, a WRITE permission this
module deliberately does not hold.
Signed in as yourself, the capability comes from
your own SharePoint Administrator role instead, and the app gains nothing: the same
bargain Connect-MsecAdmin makes.

-Interactive NEEDS A ClientId, and PnP 3.x no longer ships a default app - it fails
with "Please specify a valid client id for an Entra ID App Registration".
Use an app
registered in your own tenant with the DELEGATED SharePoint permission
AllSites.FullControl; a leftover service principal for a retired multi-tenant app
fails at sign-in with AADSTS700016 even though it still lists in the directory.

So for a delegated SharePoint session, either use the SharePoint admin centre, or
register a PUBLIC CLIENT app with delegated SharePoint permissions and a redirect URI
and use PnP's own browser flow: Connect-PnPOnline -Url \<site\> -Interactive -ClientId
\<appid\>.
That flow does not touch the Windows broker, so it works on macOS and Linux,
where Connect-MicrosoftTeams's interactive sign-in does not.
The msec app cannot be used
for it - it holds APPLICATION permissions and has no redirect URI.

Tenant-level cmdlets (Get-PnPTenantSite, Set-PnPTenant) require the ADMIN host -
contoso-admin.sharepoint.com - not the tenant root.
PnP will say so if you connect to
the wrong one, but the message is easy to misread as a permission failure.

## RELATED LINKS
