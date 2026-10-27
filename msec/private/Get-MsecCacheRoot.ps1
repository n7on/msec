function Get-MsecCacheRoot {
    <#
    .SYNOPSIS
        The directory msec keeps its local state in, honouring MSEC_CACHE_DIR.

    .DESCRIPTION
        Extracted so the tenant-scoped caches and the cross-tenant context store cannot
        disagree about where "here" is. Get-MsecCachePath builds tenant subfolders under this;
        the context store sits at the root, because a named context EXISTS to pick a tenant
        and therefore cannot be filed under one.

        MSEC_CACHE_DIR is honoured in both, which is what keeps the test suite off a
        developer's real cache.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $dir = $env:MSEC_CACHE_DIR
    if (-not $dir) {
        $base = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not $base) {
            # GetFolderPath returns empty rather than throwing on minimal Linux containers where
            # neither XDG_DATA_HOME nor HOME is set the way .NET expects.
            $base = Join-Path ($HOME ?? [System.IO.Path]::GetTempPath()) '.local/share'
        }
        $dir = Join-Path $base 'msec'
    }
    $dir
}
