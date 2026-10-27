function Get-MsecBusinessCentralToken {
    <#
    .SYNOPSIS
        A delegated Business Central token for the signed-in user, plus the API base.

    .DESCRIPTION
        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP, and the reason is structural rather
        than a preference. Business Central's only application permissions are
        API.ReadWrite.All and Automation.ReadWrite.All - there is no read-only variant. Granting
        either to the msec app would break the promise that the certificate in Key Vault cannot
        change the tenant, and it would do so over a finance system. A delegated token carries
        the signed-in person's own Business Central permissions and grants nothing that did not
        already exist, which is the same reasoning Get-MsecPowerPlatformEnvironment uses for the
        Power Platform admin APIs.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount first - this command runs as you, not as the msec app.'
    }

    $resource = 'https://api.businesscentral.dynamics.com'
    $tokenResp = Get-AzAccessToken -ResourceUrl $resource -ErrorAction Stop

    # SecureString on Az.Accounts 5.x+, plain string before that - same as Get-MsecAzureSecureScore.
    $token = if ($tokenResp.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResp.Token).Password
    }
    else { [string] $tokenResp.Token }

    [PSCustomObject]@{
        Resource = $resource
        Headers  = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
    }
}
