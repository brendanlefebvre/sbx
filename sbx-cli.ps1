#requires -Version 7
# External entry point for `sbx`, used by sbx.cmd so the launcher works from
# cmd.exe (and any non-PowerShell shell) too. PowerShell users get the faster
# in-session function that $PROFILE dot-sources from sbx.ps1; this spawns a fresh
# pwsh per call, which is what cmd needs.
. "$PSScriptRoot\sbx.ps1"
try {
    Invoke-Sbx @args
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
