function Get-MsecPurviewRetention {
    <#
    .SYNOPSIS
        Retention labels and retention policies, with whether either is actually in force.

    .DESCRIPTION
        Records management has two halves that are easy to mistake for one. A retention LABEL
        says what to do with an item; a retention POLICY says where the rule applies. A label
        with no policy publishing it does nothing at all, and the label list gives no hint of
        that - which is how a tenant ends up appearing to have retention while retaining
        nothing.

        AN EMPTY POLICY LIST DOES NOT MEAN THERE ARE NO POLICIES. Get-RetentionCompliancePolicy
        is scoped by the connecting identity's compliance role groups, and an identity without
        retention rights gets an EMPTY SET rather than access-denied. Measured directly: an
        app-only identity holding Global Reader returned 4 DLP policies, 3 sensitivity labels,
        2 label policies, 60 alert policies and 1 retention LABEL - and 0 retention policies,
        while the portal showed one. The cmdlet existed, ran, and reported nothing.

        That is the worst failure shape available: indistinguishable from a tenant with no
        retention at all, and the conclusion it invites - "nothing is retained" - is exactly
        the one a records-management report must not get wrong. So a zero here always warns.
        Reading retention policies needs a role group such as View-Only Retention Management;
        Global Reader is not enough.

        BOTH KINDS COME BACK IN ONE STREAM, tagged by Kind ('Label' or 'Policy'), because the
        question is almost always "what retention do we have" rather than one or the other. Use
        -Kind to take a side. IsInForce is the column that matters: false on an unpublished
        label, false on a disabled policy.

        AN EMPTY RESULT IS NOT AN ERROR AND THE COMMAND DOES NOT THROW ON ONE - but for the
        policy half it is not a finding either. A report should say "no retention policies were
        visible to this identity", naming the limit, rather than "no retention is configured".
        The label half is different: Get-ComplianceTag is readable under Global Reader, so an
        empty label list can be reported as measured.

    .PARAMETER Kind
        Limit to 'Label' or 'Policy'. Both by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewRetention | Format-Table Kind, Name, Action, Duration, IsInForce

    .EXAMPLE
        # Labels that exist but are published by no policy, so retain nothing.
        Get-MsecPurviewRetention -Kind Label | Where-Object { -not $_.IsInForce }

    .OUTPUTS
        One PSCustomObject per label or policy, PSTypeName 'MsecPurviewRetention'.

    .NOTES
        Needs Connect-Msec. The compliance session is opened automatically on first use - that
        handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
        than done silently. Call Connect-MsecPurview yourself to control -Organization, or to
        choose when those 102 cmdlet names land in your runspace.

        EXCHANGE MRM RETENTION IS A DIFFERENT SYSTEM AND IS NOT READ HERE. Get-RetentionPolicy
        and Get-RetentionPolicyTag live in the Exchange Online session, not the compliance one,
        and govern mailboxes independently of everything above. A tenant can show no Purview
        retention while Exchange is deleting mail on a schedule, so "no retention" drawn from
        this command alone is a statement about Purview only.

        Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateSet('Label', 'Policy')]
        [string] $Kind
    )

    Initialize-MsecExoSession -Endpoint Compliance

    # Checked per half, and only for the half actually being read: a tenant that exposes one and
    # not the other can still answer -Kind for the side that works, and the message says so.
    if (-not $Kind -or $Kind -eq 'Label') {
        Assert-MsecExoCmdlet -Name 'Get-ComplianceTag' -Feature 'retention labels' `
            -Hint 'Use -Kind Policy to read the half that is available.'
    }
    if (-not $Kind -or $Kind -eq 'Policy') {
        Assert-MsecExoCmdlet -Name 'Get-RetentionCompliancePolicy' -Feature 'retention policies' `
            -Hint 'Use -Kind Label to read the half that is available.'
    }

    if (-not $Kind -or $Kind -eq 'Label') {
        foreach ($tag in @(Get-ComplianceTag -ErrorAction Stop)) {
            [PSCustomObject]@{
                PSTypeName    = 'MsecPurviewRetention'
                Kind          = 'Label'
                Name          = [string] $tag.Name
                Action        = [string] $tag.RetentionAction
                Duration      = [string] $tag.RetentionDuration
                RetentionType = [string] $tag.RetentionType
                IsRecordLabel = [bool] $tag.IsRecordLabel
                # A label nothing publishes cannot apply to anything.
                IsInForce     = [bool] $tag.Published
                Enabled       = $null
                Locations     = $null
                Notes         = [string] $tag.Notes
                WhenChangedUtc = $tag.WhenChanged
            }
        }
    }

    if (-not $Kind -or $Kind -eq 'Policy') {
        $policies = @(Get-RetentionCompliancePolicy -ErrorAction Stop)

        # ZERO IS UNVERIFIABLE HERE, so it is reported rather than returned silently. An
        # identity without retention rights gets an empty set, not an error, so "no policies
        # exist" and "this identity cannot see policies" arrive looking identical. There is no
        # signal in the response to tell them apart - hence a warning every time rather than a
        # heuristic that would be confidently wrong some of the time.
        if ($policies.Count -eq 0) {
            Write-Warning ('No retention policies returned. This is NOT proof that none exist: ' +
                'Get-RetentionCompliancePolicy is scoped by the connecting identity''s compliance ' +
                'role groups and returns an EMPTY SET rather than access-denied when retention ' +
                'rights are missing. Global Reader is not sufficient - a role group such as ' +
                'View-Only Retention Management is. Confirm in the Purview portal under Data ' +
                'Lifecycle Management before reporting that nothing is retained.')
        }

        foreach ($policy in $policies) {
            $locations = @(
                foreach ($n in 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation',
                               'ModernGroupLocation', 'TeamsChannelLocation', 'TeamsChatLocation') {
                    $resolved = Resolve-MsecPurviewLocation $policy.$n
                    if ($resolved.Scope -ne 'None') { "$($n -replace 'Location','')=$($resolved.Scope)" }
                }
            )

            [PSCustomObject]@{
                PSTypeName    = 'MsecPurviewRetention'
                Kind          = 'Policy'
                Name          = [string] $policy.Name
                Action        = $null
                Duration      = $null
                RetentionType = $null
                IsRecordLabel = $null
                IsInForce     = [bool] $policy.Enabled
                Enabled       = [bool] $policy.Enabled
                Locations     = $locations
                Notes         = [string] $policy.Comment
                WhenChangedUtc = $policy.WhenChanged
            }
        }
    }
}
