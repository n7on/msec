function Get-MsecBusinessCentralEnvironment {
    <#
    .SYNOPSIS
        Dynamics 365 Business Central environments - production and sandbox - with how many
        companies and users each one carries.

    .DESCRIPTION
        A SANDBOX IS NOT A LOWER-SENSITIVITY ENVIRONMENT, which is the reason this command
        exists. A Business Central sandbox is routinely created by copying production, so it can
        hold the same financial data, and it carries its OWN user list and its OWN permission
        assignments - granted separately, reviewed separately, and usually reviewed less. An
        access review that covers production and stops there has covered a fraction of the
        estate. Measured on one tenant: two production environments and three sandboxes, with
        the sandboxes holding 33, 37 and 45 users.

        THE COMMAND DOES NOT CLAIM TO DETECT A PRODUCTION COPY. The admin API exposes no field
        saying where a sandbox came from, so inferring it from a name containing 'COPY' would be
        a guess dressed as a measurement. Type, company count and user count are reported and
        the judgement is left to the reader - a sandbox with as many companies as production is
        worth a question whatever it is called.

        COUNTS COST A REQUEST EACH, so -Quick skips them when the environment list alone is
        wanted. A count that could not be read is $null rather than 0: an environment nobody
        could enumerate must not render as an empty one.

        Runs as the signed-in user - see the note below.

    .PARAMETER Quick
        Environment list only. Skips the per-environment company and user counts.

    .PARAMETER SandboxOnly
        Only non-production environments.

    .EXAMPLE
        Get-MsecBusinessCentralEnvironment

        Every environment with its company and user counts.

    .EXAMPLE
        Get-MsecBusinessCentralEnvironment -SandboxOnly

        The environments most likely to hold production data under least scrutiny.

    .EXAMPLE
        Get-MsecBusinessCentralEnvironment | Where-Object { $_.Type -ne 'Production' -and $_.Users -gt 20 }

        Non-production environments with a real user population behind them.

    .OUTPUTS
        PSCustomObject per environment, PSTypeName 'MsecBusinessCentralEnvironment'.

    .NOTES
        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP. Business Central offers only
        API.ReadWrite.All and Automation.ReadWrite.All as application permissions - there is no
        read-only variant - so granting one to the msec app would let the Key Vault certificate
        write to a finance system. A delegated token carries your own Business Central
        permissions and grants nothing new. Same pattern as Get-MsecPowerPlatformEnvironment.

        Needs Connect-AzAccount, not Connect-Msec.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $Quick,
        [switch] $SandboxOnly
    )

    $ctx = Get-MsecBusinessCentralToken
    $res = $ctx.Resource
    $headers = $ctx.Headers

    try {
        $environments = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
            -Uri "$res/admin/v2.24/applications/businesscentral/environments").value)
    }
    catch {
        $status = if ($_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { $null }
        if ($status -in 401, 403) {
            throw "Business Central admin API returned $status. This command runs as the signed-in user and needs a Business Central or Dynamics 365 administrator role. Original: $($_.Exception.Message)"
        }
        throw "Could not list Business Central environments: $($_.Exception.Message)"
    }

    foreach ($e in $environments) {
        $name = [string] $e.name
        if ($SandboxOnly -and [string]$e.type -eq 'Production') { continue }

        # $null, not 0, when a count could not be taken - an environment that refused
        # enumeration must not read as an empty one.
        $companies = $null
        $users     = $null

        if (-not $Quick) {
            $companyList = $null
            try {
                $companyList = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
                    -Uri "$res/v2.0/$name/api/v2.0/companies").value)
                $companies = $companyList.Count
            }
            catch {
                Write-Verbose "Could not list companies in '$name': $($_.Exception.Message)"
            }

            if ($companyList -and $companyList.Count) {
                # The users list is per-environment, not per-company - the route needs a company
                # id but the result spans the environment, so one call answers it.
                try {
                    $users = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Method Get `
                        -Uri "$res/v2.0/$name/api/microsoft/automation/v2.0/companies($($companyList[0].id))/usersPermissions").value).Count
                }
                catch {
                    Write-Verbose "Could not read users in '$name': $($_.Exception.Message)"
                }
            }
        }

        [PSCustomObject]@{
            PSTypeName         = 'MsecBusinessCentralEnvironment'
            Name               = $name
            FriendlyName       = [string] $e.friendlyName
            # Production or Sandbox. NOT a statement about what data is inside it.
            Type               = [string] $e.type
            Status             = [string] $e.status
            CountryCode        = [string] $e.countryCode
            Companies          = $companies
            Users              = $users
            ApplicationVersion = [string] $e.applicationVersion
            PlatformVersion    = [string] $e.platformVersion
            LocationName       = [string] $e.locationName
            GeoName            = [string] $e.geoName
            RingName           = [string] $e.ringName
            WebClientUrl       = [string] $e.webClientLoginUrl
            LinkedPowerPlatformEnvironmentId = [string] $e.linkedPowerPlatformEnvironmentId
        }
    }
}
