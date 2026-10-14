function Get-MsecIntuneDeviceCompliance {
    <#
    .SYNOPSIS
        Why each device is non-compliant - the policy and the individual setting that failed,
        separating devices that break a security control from devices that merely went quiet.

    .DESCRIPTION
        Get-MsecIntuneDevice reports THAT a device is non-compliant. The reason lives two
        levels below it and nothing surfaces it: the failing policy is on
        /managedDevices/{id}/deviceCompliancePolicyStates and the failing SETTING is a further
        call per policy. This command makes that join, one row per device per failing setting.

        MOST NON-COMPLIANCE IS NOT A SECURITY FAILURE, AND TREATING IT AS ONE IS THE MISTAKE
        THIS COMMAND EXISTS TO PREVENT. Intune ships a built-in 'Default Device Compliance
        Policy' whose rules are housekeeping - has the device checked in recently
        (RequireRemainContact), does the owning account still exist (RequireUserExistence), is
        any policy assigned at all (RequireDeviceCompliancePolicyAssigned). A device failing
        those is stale, not insecure. Measured on one tenant: 33 non-compliant devices, 30
        attributable failures, and every single one from the default policy - not one device
        failed encryption, OS version or any configured baseline. Category marks each row
        'Housekeeping' or 'SecurityControl' so a report can say which it found.

        A FAILED READ AND AN EMPTY ONE ARE DIFFERENT, AND BOTH ARE REPORTED. Intune throttles
        this endpoint hard - two calls per device - and Invoke-MsecGraphRequest gives up after
        five retries, so on a tenant of any size some devices lose their read to a 429.
        Category 'Unreadable' marks those; 'Unattributed' means the call SUCCEEDED and
        returned nothing. Collapsing the two was the original behaviour and it made the output
        differ run to run: the same tenant gave 4 unattributed devices on one pass and 9 on
        the next, and one of them had three perfectly readable settings when queried alone.
        The run also warns when anything was unreadable, because a silently short report is
        worse than a slow one.

        A DEVICE WHOSE SETTINGS CANNOT BE ATTRIBUTED IS REPORTED, NOT DROPPED. A device can be
        flagged non-compliant while its settingStates return nothing - measured, 4 of 33 - and
        omitting those rows would quietly shrink the problem. They come back with Category
        'Unattributed' and a null Setting, because "we could not determine why" and "there is
        nothing wrong" must not look the same.

        READ settingName, NOT setting. The 'setting' property is present and EMPTY on every
        row the v1.0 endpoint returns; the human-readable rule is in 'settingName'. Reading
        the obvious one yields a column of blanks that looks like missing data.

        THIS COSTS TWO GRAPH CALLS PER DEVICE, which is why it defaults to non-compliant
        devices only. A tenant of any size should not pay for the compliant ones to answer a
        question about the broken ones; -IncludeCompliant lifts that when the full picture is
        actually wanted.

        Runs as the msec app. Needs 'DeviceManagementManagedDevices.Read.All'.

    .PARAMETER IncludeCompliant
        Also evaluate devices that are currently compliant. Two extra Graph calls per device.

    .PARAMETER DeviceName
        Only devices whose name matches this wildcard pattern, e.g. 'VIE01*'.

    .PARAMETER SecurityOnly
        Only failures of a real configured policy - drops the built-in default policy's
        housekeeping rules, which is usually what someone means by "non-compliant devices".

        ROWS WHOSE REASON COULD NOT BE READ ARE STILL RETURNED, because an unreadable reason
        might be a security failure and this is the view someone uses to find those. Filter
        them out explicitly with Where-Object Category -eq 'SecurityControl' if you want only
        what is confirmed.

    .EXAMPLE
        Get-MsecIntuneDeviceCompliance

    .EXAMPLE
        # The failures that actually indicate an insecure device.
        Get-MsecIntuneDeviceCompliance -SecurityOnly

    .EXAMPLE
        # What is actually wrong, tenant-wide.
        Get-MsecIntuneDeviceCompliance | Group-Object Setting | Sort-Object Count -Descending

    .OUTPUTS
        PSCustomObject per device per failing setting, PSTypeName 'MsecIntuneDeviceCompliance'.

    .NOTES
        Read-only. A device that has not checked in cannot be remediated by Intune at all -
        policy only applies when the device talks to the service - so DaysQuiet is the column
        that decides whether a finding is actionable or whether the device simply needs
        retiring.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $IncludeCompliant,
        [string] $DeviceName,
        [switch] $SecurityOnly
    )

    Assert-MsecSession

    $devices = @(Get-MsecIntuneDevice)
    if ($DeviceName) { $devices = @($devices | Where-Object { $_.DeviceName -like $DeviceName }) }
    if (-not $IncludeCompliant) {
        $devices = @($devices | Where-Object { $_.ComplianceState -notin @('compliant', 'unknown') })
    }

    $now = [datetime]::UtcNow
    $i = 0
    # Counted so the run can say how much of its own output it could not actually read.
    $script:MsecComplianceUnreadable = 0

    foreach ($d in $devices) {
        $i++
        Write-Progress -Id 1820 -Activity 'Reading device compliance' `
            -Status "$i of $($devices.Count) - $($d.DeviceName)" `
            -PercentComplete (100 * ($i - 1) / [Math]::Max(1, $devices.Count))

        $daysQuiet = if ($d.LastSyncDateTime) { [int]($now - $d.LastSyncDateTime.ToUniversalTime()).TotalDays } else { $null }

        $states = @()
        # A FAILED READ IS NOT AN EMPTY RESULT, and on this endpoint the difference is
        # routine rather than theoretical: two calls per device makes Intune's compliance
        # endpoints throttle, and Invoke-MsecGraphRequest gives up after 5 retries. Treating
        # the exhausted call as "no settings" turns a transient 429 into a device that looks
        # like it has nothing wrong with it - and makes the output differ run to run, which
        # is how it was first noticed.
        $readFailed = $false
        try {
            $states = @(Invoke-MsecGraphRequest -All `
                -Path "/v1.0/deviceManagement/managedDevices/$($d.Id)/deviceCompliancePolicyStates")
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw ("Forbidden reading deviceCompliancePolicyStates. The msec app needs " +
                       "'DeviceManagementManagedDevices.Read.All' (admin consent required). " +
                       "Original error: $($_.Exception.Message)")
            }
            $readFailed = $true
            $script:MsecComplianceUnreadable++
            Write-Verbose "Could not read policy states for $($d.DeviceName): $($_.Exception.Message)"
        }

        $failing = @($states | Where-Object { $_.state -eq 'nonCompliant' })

        # A non-compliant device with nothing to attribute it to still has to appear. Dropping
        # it would make the problem look smaller than it is.
        if (-not $failing -and $d.ComplianceState -eq 'noncompliant') {
            [PSCustomObject]@{
                PSTypeName  = 'MsecIntuneDeviceCompliance'
                DeviceName  = $d.DeviceName
                Os          = $d.Os
                Owner       = $d.UserPrincipalName
                PolicyName  = $null
                Setting     = $null
                # Not 'nothing wrong' - 'could not determine what'.
                # 'Unreadable' when the call FAILED, 'Unattributed' when it succeeded and
                # returned nothing. A throttled read must not look like a clean device.
                Category    = if ($readFailed) { 'Unreadable' } else { 'Unattributed' }
                LastSyncUtc = $d.LastSyncDateTime
                DaysQuiet   = $daysQuiet
                DeviceId    = $d.Id
            }
            continue
        }

        foreach ($pol in $failing) {
            $settings = @()
            $settingReadFailed = $false
            try {
                $settings = @(Invoke-MsecGraphRequest -All `
                    -Path "/v1.0/deviceManagement/managedDevices/$($d.Id)/deviceCompliancePolicyStates/$($pol.id)/settingStates")
            }
            catch {
                $settingReadFailed = $true
                $script:MsecComplianceUnreadable++
                Write-Verbose "Could not read setting states for $($d.DeviceName)/$($pol.displayName)"
            }

            $bad = @($settings | Where-Object { $_.state -eq 'nonCompliant' })

            # The policy failed but no setting within it did - same ambiguity as above, one
            # level down, and reported the same way rather than silently skipped.
            if (-not $bad) {
                $row = [PSCustomObject]@{
                    PSTypeName  = 'MsecIntuneDeviceCompliance'
                    DeviceName  = $d.DeviceName
                    Os          = $d.Os
                    Owner       = $d.UserPrincipalName
                    PolicyName  = [string]$pol.displayName
                    Setting     = $null
                    # Same distinction one level down: the policy failed but the settings
                    # could not be read, which is not the same as there being none.
                    Category    = if ($settingReadFailed) { 'Unreadable' } else { 'Unattributed' }
                    LastSyncUtc = $d.LastSyncDateTime
                    DaysQuiet   = $daysQuiet
                    DeviceId    = $d.Id
                }
                # NOT filtered by -SecurityOnly: an unreadable reason might BE a security
                # failure, and the view someone uses to find those is the worst place for it
                # to vanish from.
                $row
                continue
            }

            foreach ($s in $bad) {
                # The built-in default policy's rules are housekeeping: checked in recently,
                # account still exists, any policy assigned. Failing one means stale, not
                # insecure, and the distinction is the whole point of the command.
                $name = [string]$s.settingName
                $isDefault = $name -like 'DefaultDeviceCompliancePolicy.*'
                $category  = if ($isDefault) { 'Housekeeping' } else { 'SecurityControl' }

                if ($SecurityOnly -and $category -ne 'SecurityControl') { continue }

                [PSCustomObject]@{
                    PSTypeName  = 'MsecIntuneDeviceCompliance'
                    DeviceName  = $d.DeviceName
                    Os          = $d.Os
                    Owner       = $d.UserPrincipalName
                    PolicyName  = [string]$pol.displayName
                    # settingName, not setting - 'setting' is empty on every v1.0 row.
                    Setting     = $name
                    Category    = $category
                    LastSyncUtc = $d.LastSyncDateTime
                    # A device that has not checked in cannot be remediated by Intune at all.
                    DaysQuiet   = $daysQuiet
                    DeviceId    = $d.Id
                }
            }
        }
    }


    Write-Progress -Id 1820 -Activity 'Reading device compliance' -Completed

    # SAID OUT LOUD, because the alternative is a run that silently under-reports. Intune's
    # compliance endpoints throttle under two calls per device and the Graph helper gives up
    # after 5 retries, so a large tenant can lose devices to 429s - and the loss is invisible
    # in the output except as rows that would otherwise look like nothing is wrong.
    if ($script:MsecComplianceUnreadable -gt 0) {
        Write-Warning ("$($script:MsecComplianceUnreadable) compliance read(s) failed and are " +
            "reported as Category 'Unreadable' rather than as clean devices. The usual cause " +
            'is Microsoft Graph throttling: this command makes two calls per device and ' +
            'Intune throttles that endpoint hard. Re-run, or narrow with -DeviceName, to ' +
            'attribute them.')
    }
}
