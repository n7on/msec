function Get-MsecDefenderIndicator {
    <#
    .SYNOPSIS
        Every custom indicator of compromise in Defender for Endpoint - one row per indicator,
        with what it matches, what it does, who created it and whether it ever expires.

    .DESCRIPTION
        New-MsecDefenderIndicator could create one and nothing could list them, so the only way
        to see what was already in place was the portal. This answers "what are we already
        blocking, allowing or auditing, and who decided that".

        THIS API HAS NO READ-ONLY PERMISSION, WHICH MAKES THIS A Get-* THAT NEEDS A WRITE
        SCOPE. Listing indicators requires Ti.ReadWrite - normally through the Security
        Administrator role - because Microsoft never shipped a Ti.Read. That is surprising
        enough to state before anything else: this command reads, but the permission it needs
        can also write, and no narrower one exists to ask for.

        IT RUNS ON THE Az CONTEXT, AS YOU - not as the msec app. The app holds *.Read.All and
        is deliberately NOT given Ti.ReadWrite: adding a write permission to the read-only
        identity so that a read becomes convenient is exactly the trade this module refuses.
        So this needs Connect-MsecAzure, and what you can see is what your own roles allow.

        AN INDICATOR WITH NO EXPIRY NEVER EXPIRES, and that is the normal case rather than the
        exception - measured on one tenant, 63 of 63 had no expirationTime at all. ExpiresUtc
        is $null for those, never a date far in the future, because "permanent" and "expires
        in 2099" are different facts and a report that conflates them is lying quietly.

        AN EMPTY SCOPE MEANS TENANT-WIDE, NOT UNSCOPED. rbacGroupNames comes back empty when
        an indicator applies to every device, which reads like missing data and is the
        opposite - measured on the same tenant, 0 of 63 were scoped to a device group, so all
        63 applied everywhere. Scope is reported as 'Tenant-wide' rather than left blank.

        COMMERCIAL CLOUD ONLY. Defender for Endpoint has no securitycenter endpoint in the
        sovereign clouds, so this throws there rather than returning an empty list.

    .PARAMETER Type
        Indicator types to return - FileSha256, FileSha1, FileMd5, IpAddress, DomainName, Url,
        CertificateThumbprint, WebCategory. Matched case-insensitively against what the API
        returns, and an unknown name is NOT an error: it filters to nothing and says so, since
        Microsoft adds types without warning.

    .PARAMETER Action
        Actions to return - Allowed, Audit, Block, BlockAndRemediate, Warn. Same matching
        rules as -Type.

    .PARAMETER Value
        Wildcard filter on the indicator value itself, e.g. '*.example.com' or a partial hash.

    .PARAMETER CreatedBy
        Wildcard filter on the creating account.

    .EXAMPLE
        Get-MsecDefenderIndicator | Group-Object Action, Type | Sort-Object Count -Descending

        What the tenant is actually enforcing, and in what proportion. On one tenant: 36 Audit,
        20 Block, 7 Allowed - so more than half of it was watching rather than stopping.

    .EXAMPLE
        Get-MsecDefenderIndicator -Action Allowed

        The allow-list, which is the half of this worth reviewing most often - every entry is
        something the product WOULD have stopped.

    .OUTPUTS
        One PSCustomObject per indicator, PSTypeName 'MsecDefenderIndicator'. Raw keeps the
        untouched API object.

    .NOTES
        Needs Connect-MsecAzure and the Ti.ReadWrite scope on YOUR account - Security
        Administrator or equivalent. The msec app cannot do this and is not asked to.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]] $Type,
        [string[]] $Action,
        [string]   $Value,
        [string]   $CreatedBy
    )

    $endpoints = Get-MsecEnvironment
    $defender  = $endpoints.DefenderResource
    if (-not $defender) {
        throw ("Microsoft Defender for Endpoint has no endpoint in the '$($endpoints.EnvironmentName)' cloud, " +
               'so indicators cannot be listed here. This API is commercial-only.')
    }

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-MsecAzure before Get-MsecDefenderIndicator - this reads as you, not as the msec app.'
    }

    $tokenResponse = Get-AzAccessToken -ResourceUrl $defender -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }
    $headers = @{ Authorization = "Bearer $token" }

    # PAGED DEFENSIVELY. One tenant returned all 63 in a single response with no
    # @odata.nextLink, but the indicator limit is in the thousands and a silently truncated
    # security inventory is worse than a slow one.
    $raw = [System.Collections.Generic.List[object]]::new()
    $uri = "$defender/api/indicators"
    try {
        while ($uri) {
            $page = Invoke-RestMethod -Headers $headers -Uri $uri -ErrorAction Stop
            foreach ($i in @($page.value)) { $raw.Add($i) }
            $uri = $page.'@odata.nextLink'
        }
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw ("Forbidden listing Defender indicators as $($context.Account.Id). This API has NO read-only " +
                   'permission - listing requires the Ti.ReadWrite scope, normally through the Security ' +
                   "Administrator role. This is an authorization failure on YOUR account, not on the msec app. " +
                   "Original error: $detail")
        }
        throw "Could not list Defender indicators: $detail"
    }

    $rows = foreach ($i in $raw) {
        # EMPTY SCOPE IS TENANT-WIDE. See the help - blank here reads as missing data and means
        # the opposite.
        $groups = @($i.rbacGroupNames | Where-Object { $_ })
        $scope  = if ($groups.Count) { $groups -join '; ' } else { 'Tenant-wide' }

        [PSCustomObject]@{
            PSTypeName     = 'MsecDefenderIndicator'
            Value          = [string] $i.indicatorValue
            Type           = [string] $i.indicatorType
            Action         = [string] $i.action
            Severity       = [string] $i.severity
            Title          = [string] $i.title
            Scope          = $scope
            GenerateAlert  = [bool] $i.generateAlert
            CreatedBy      = [string] $i.createdBy
            CreatedSource  = [string] $i.createdBySource
            CreatedUtc     = $i.creationTimeDateTimeUtc
            LastUpdatedUtc = $i.lastUpdateTime
            # $null, never a far-future date: "never expires" is a different fact from "expires
            # eventually", and most indicators are the former.
            ExpiresUtc     = if ($i.expirationTime) { [datetime] $i.expirationTime } else { $null }
            Id             = [string] $i.id
            Raw            = $i
        }
    }
    $rows = @($rows)

    if ($Type) {
        $known = @($rows.Type | Sort-Object -Unique)
        $unknown = @($Type | Where-Object { $_ -notin $known })
        if ($unknown.Count) {
            Write-Warning ("No indicator has type(s): $($unknown -join ', '). Present in this tenant: " +
                           "$($known -join ', '). Microsoft adds types without warning, so this is a filter " +
                           'that matched nothing rather than an invalid value.')
        }
        $rows = @($rows | Where-Object { $_.Type -in $Type })
    }
    if ($Action) {
        $known = @($rows.Action | Sort-Object -Unique)
        $unknown = @($Action | Where-Object { $_ -notin $known })
        if ($unknown.Count) {
            Write-Warning ("No indicator has action(s): $($unknown -join ', '). Present in this tenant: " +
                           "$($known -join ', ').")
        }
        $rows = @($rows | Where-Object { $_.Action -in $Action })
    }
    if ($Value)     { $rows = @($rows | Where-Object { $_.Value -like $Value }) }
    if ($CreatedBy) { $rows = @($rows | Where-Object { $_.CreatedBy -like $CreatedBy }) }

    $rows
}
