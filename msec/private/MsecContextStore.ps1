function Get-MsecContextStorePath {
    <#
    .SYNOPSIS
        Path of the named-context store. One file at the cache root, not per tenant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-MsecCacheRoot) 'contexts.json'
}

function Read-MsecContextStore {
    <#
    .SYNOPSIS
        Every saved context, as an ordered hashtable keyed by name. Empty when there are none.

    .DESCRIPTION
        A MISSING OR UNREADABLE STORE IS EMPTY, NOT AN ERROR. Losing saved contexts costs the
        convenience of switching by name; failing here would take the module's commands down
        with it. The same trade the tenant profile makes.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $out = [ordered]@{}
    $path = Get-MsecContextStorePath
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($p in $raw.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    catch {
        Write-Verbose "Could not read the context store at $path : $($_.Exception.Message)"
    }
    $out
}

function Write-MsecContextStore {
    <#
    .SYNOPSIS
        Replaces the store. Best effort - a store that cannot be written costs the
        convenience, not the session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Contexts)

    $path = Get-MsecContextStorePath
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        ($Contexts | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8 -ErrorAction Stop
        Write-Verbose "Wrote $(@($Contexts.Keys).Count) context(s) to $path"
        $true
    }
    catch {
        Write-Warning "Could not write the context store at $path : $($_.Exception.Message) Saved contexts will not persist."
        $false
    }
}
