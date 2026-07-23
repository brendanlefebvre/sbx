@echo off
rem sbx launcher shim so `sbx` works from cmd.exe (and any non-PowerShell shell).
rem PowerShell users get the faster in-session function from $PROFILE instead.
pwsh -NoProfile -File "%~dp0sbx-cli.ps1" %*
exit /b %ERRORLEVEL%
