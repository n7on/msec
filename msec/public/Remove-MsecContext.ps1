function Remove-MsecContext {
    <#
    .SYNOPSIS
        Forgets a saved context. Disconnects nothing.

    .DESCRIPTION
        Removes the entry only. Any session currently established stays exactly as it is -
        this command is about the list you switch from, not the sessions you are in.

    .PARAMETER Name
        The context to forget. Tab-completes the saved names.

    .EXAMPLE
        Remove-MsecContext old-prod
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                $word = ([string]$wordToComplete).Trim("'`"")
                try { $names = (& (Get-Module Msec) { (Read-MsecContextStore).Keys }) } catch { return }
                $names | Where-Object { $_ -like "$word*" } | ForEach-Object {
                    $t = if ($_ -match '[\s'']') { "'" + ($_ -replace "'", "''") + "'" } else { $_ }
                    [System.Management.Automation.CompletionResult]::new($t, $_, 'ParameterValue', $_)
                }
            })]
        [string] $Name
    )

    $store = Read-MsecContextStore
    if (-not $store.Contains($Name)) {
        Write-Warning "No saved context named '$Name'. Get-MsecContext -List shows what there is."
        return
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Forget msec context')) {
        $store.Remove($Name)
        $null = Write-MsecContextStore -Contexts $store
        Write-Verbose "Removed context '$Name'. No session was disconnected."
    }
}
