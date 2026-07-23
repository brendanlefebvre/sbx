function ConvertFrom-SbxArgs {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    # Default is foreground ('here'): a bare `sbx` runs in the current terminal so
    # SSH users never have to remember a flag. `--new-window` (aka `--window`/`--win`)
    # opts into spawning a GUI window — Windows-only (see Resolve-SbxWindow).
    $opts = [ordered]@{ Command = 'attach'; Target = $null; Operation = $null; Window = 'here' }
    $positional = [System.Collections.Generic.List[string]]::new()

    foreach ($arg in $Arguments) {
        switch ($arg) {
            '--new-window' { $opts.Window = 'window' }
            '--window'     { $opts.Window = 'window' }
            '--win'        { $opts.Window = 'window' }
            '--tab'        { $opts.Window = 'tab' }
            default        {
                if ($arg -like '--*') { throw "Unknown option: $arg" }
                $positional.Add($arg)
            }
        }
    }
    if ($positional.Count -eq 0) { return [pscustomobject]$opts }

    switch ($positional[0]) {
        'add' {
            if ($positional.Count -lt 2) { throw "sbx: 'add' expects a path" }
            $opts.Command = 'add'; $opts.Target = $positional[1]
        }
        'rm' {
            if ($positional.Count -lt 2) { throw "sbx: 'rm' expects a project name" }
            if ($positional[1] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'rm'; $opts.Target = $positional[1]
        }
        'sync' {
            if ($positional.Count -lt 3) { throw "sbx: 'sync' expects <name> <push|pull|fetch>" }
            if ($positional[1] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'sync'; $opts.Target = $positional[1]; $opts.Operation = $positional[2]
        }
        'ls'      { $opts.Command = 'ls' }
        'rebuild' { $opts.Command = 'rebuild' }
        'stop'    { $opts.Command = 'stop' }
        'scratch' { $opts.Command = 'scratch' }
        'status'  { $opts.Command = 'status' }
        default {
            if ($positional[0] -match '[\\/]') {
                throw "sbx: '$($positional[0])' looks like a path — v2 takes project names; run 'sbx add <path>' once, then 'sbx <name>'"
            }
            if ($positional[0] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'attach'; $opts.Target = $positional[0]
        }
    }
    return [pscustomobject]$opts
}

function ConvertTo-SbxMountPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostPath, [switch]$Posix)

    if ($Posix) {
        if ($HostPath -notmatch '^/') {
            throw "Unsupported host path (need an absolute POSIX path): $HostPath"
        }
        $t = $HostPath.TrimEnd('/')
        return ($(if ($t) { $t } else { '/' }))   # never collapse root to empty
    }

    $p = $HostPath -replace '/', '\'          # normalize to backslashes
    $p = $p.TrimEnd('\')                       # drop trailing slash
    if ($p -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Unsupported host path (need a drive-letter path): $HostPath"
    }
    # WINNING FORM per docs/FINDINGS.md: host Windows drive-letter path,
    # forward-slash normalized (backslash also binds, but forward slashes are
    # safe across the wt.exe -> pwsh -Command string hop). The /mnt/c form
    # was tested and mounts an empty location — never emit it.
    $drive = $matches[1].ToUpper()
    $rest  = $matches[2] -replace '\\', '/'
    return "${drive}:/$rest"
}

function Get-SbxContainerName {
    [CmdletBinding()]
    param([string]$Path, [string]$Override, [string]$Suffix)
    if ($Override) { return $Override }
    if (-not $Suffix) {
        $Suffix = -join ((48..57 + 97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $base = 'scratch' }
    else { $base = Split-Path -Leaf ($Path -replace '[\\/]+$','') }
    return "sbx-$base-$Suffix"
}

function Start-WtSbx {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$RunArgs, [string]$Name, [switch]$NewTab)
    # Build a pwsh script that SPLATS the run args (`& wslc @a`) instead of
    # re-parsing a flat command string. Passing it via -EncodedCommand means the
    # inner pwsh never re-interprets the tokens, so a path or name containing '$'
    # (a legal Windows dir name), a space, or a quote can't mangle the mount or
    # the cleanup. Each element is emitted as a single-quoted literal.
    $lit    = { "'" + ("$($args[0])" -replace "'", "''") + "'" }
    $argExpr = '@(' + (($RunArgs | ForEach-Object { & $lit $_ }) -join ',') + ')'
    # Best-effort cleanup: when the container exits (claude quits) or the window
    # is closed, stop+remove it so it doesn't linger in `sbx ls`. wslc keeps the
    # container running when the client disconnects, and a forced window close
    # only gives pwsh a brief window to run `finally`, so this is best-effort —
    # if it's ever skipped, clean up by hand with `wslc remove <name>` (or the
    # runtime-appropriate equivalent; see Remove-SbxContainer).
    $body = "`$a = $argExpr; "
    if ($Name) {
        $n  = & $lit $Name
        $np = & $lit "$Name-proj"
        # Volume remove is a no-op for containers without a -proj volume; kept
        # unconditional so windowed scratch cleanup reaps its throwaway
        # projects volume (see Build-SbxScratchArgs / Remove-SbxScratchLeftovers).
        $body += "try { & wslc @a } finally { & wslc stop $n 2>`$null; & wslc remove $n 2>`$null; & wslc volume remove $np 2>`$null }"
    } else {
        $body += "& wslc @a"
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $wt = [System.Collections.Generic.List[string]]::new()
    if ($NewTab) {
        $wt.Add('-w'); $wt.Add('0'); $wt.Add('new-tab')
    }
    else {
        # -w -1 forces a NEW window; without it Windows Terminal may "glom" the
        # invocation into the most-recently-used window as a tab, violating the
        # new-window contract of --new-window/--window/--win.
        $wt.Add('-w'); $wt.Add('-1')
    }
    $wt.Add('pwsh'); $wt.Add('-NoExit'); $wt.Add('-EncodedCommand'); $wt.Add($encoded)
    Start-Process wt.exe -ArgumentList $wt.ToArray()
}

function Test-SbxBenignRuntimeError {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text -match '(?i)no such container|no such object|not found|is not running'
}

function Resolve-SbxRuntime {
    [CmdletBinding()]
    param([bool]$IsMac = $IsMacOS, [string]$Override = $env:SBX_RUNTIME)
    if ($Override) { return $Override }
    if ($IsMac)    { return 'docker' }
    return 'wslc'
}

function Invoke-Sbx {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())
    $runtime = Resolve-SbxRuntime
    $o = ConvertFrom-SbxArgs -Arguments $Arguments
    switch ($o.Command) {
        'ls'      { return Get-SbxProjects -Runtime $runtime }
        'add'     { return Add-SbxProject -Path $o.Target }
        'rm'      { return Remove-SbxProject -Name $o.Target -Runtime $runtime }
        'sync'    { return Invoke-SbxSync -Name $o.Target -Operation $o.Operation }
        'rebuild' { return Invoke-SbxRebuild -Runtime $runtime }
        'stop'    { return Stop-SbxMain -Runtime $runtime }
        'status'  { return Invoke-SbxStatus -Runtime $runtime }
        'scratch' {
            $name    = Get-SbxContainerName -Path $null
            $runArgs = Build-SbxScratchArgs -Name $name
            $window  = Resolve-SbxWindow -OnWindows:$IsWindows -Requested $o.Window
            switch ($window) {
                'here'  { try { & $runtime @runArgs } finally { Remove-SbxScratchLeftovers -Name $name -Runtime $runtime } }
                'tab'   { Start-WtSbx -RunArgs $runArgs -Name $name -NewTab }
                default { Start-WtSbx -RunArgs $runArgs -Name $name }
            }
            return
        }
        'attach' {
            Start-SbxMain -Runtime $runtime
            if ($o.Target) {
                $workspaceDir = Get-SbxWorkspacePath
                $projectDir = Join-Path $workspaceDir $o.Target
                if (-not (Test-Path -LiteralPath $projectDir)) {
                    throw "sbx: no project '$($o.Target)' in the workspace — 'sbx add <path>' first (or 'sbx ls')"
                }
                # Guard against traversal (`sbx ..`): the resolved dir must be a DIRECT
                # CHILD of the workspace, not merely *somewhere under* it.
                if ((Get-Item -LiteralPath $projectDir).Parent.FullName -ne (Get-Item -LiteralPath $workspaceDir).FullName) {
                    throw "sbx: no project '$($o.Target)' in the workspace — 'sbx add <path>' first (or 'sbx ls')"
                }
                $session = Get-SbxSessionName $o.Target
                $workdir = "/work/$($o.Target)"
            }
            else { $session = 'hub'; $workdir = '/work' }
            $attachArgs = Build-SbxAttachArgs -Session $session -WorkDir $workdir
            $window = Resolve-SbxWindow -OnWindows:$IsWindows -Requested $o.Window
            switch ($window) {
                'here'  { & $runtime @attachArgs }        # persistent container: no cleanup
                'tab'   { Start-WtSbx -RunArgs $attachArgs -NewTab }
                default { Start-WtSbx -RunArgs $attachArgs }
            }
            return
        }
    }
}

Set-Alias -Name sbx -Value Invoke-Sbx

function ConvertFrom-DockerPs {
    [CmdletBinding()] param([string[]]$Lines)
    # Skip anything that isn't a JSON object: a runtime invoked with flags it
    # doesn't understand prints usage text to stdout, and parsing that line-by-line
    # produces a cascade of useless ConvertFrom-Json errors.
    foreach ($line in ($Lines | Where-Object { $_ -and $_.TrimStart().StartsWith('{') })) {
        $o = $line | ConvertFrom-Json
        $status = switch -Regex ("$($o.State)") {
            '^running' { 'running'; break }
            '^exited'  { 'exited';  break }
            '^created' { 'created'; break }
            default    { if ($o.State) { "$($o.State)" } else { "$($o.Status)" } }
        }
        [pscustomobject]@{ Name = ($o.Names -split ',')[0]; Image = $o.Image; Status = $status }
    }
}

function ConvertFrom-WslcList {
    # $Json is [string[]], NOT [string]: `& wslc list --all --format json` returns one
    # array element per output line. Parameter binding refuses to convert a string[]
    # to a [string] parameter (unlike an explicit [string] cast, which joins) — that
    # mismatch broke `sbx ls` on Windows with "Cannot convert value to type
    # System.String". Join the lines back before parsing.
    [CmdletBinding()] param([string[]]$Json)
    if (-not $Json) { return }
    $raw = ($Json -join "`n").Trim()
    if (-not $raw) { return }
    @($raw | ConvertFrom-Json) |
        Where-Object { $_.Name -like 'sbx-*' } |
        Select-Object Name, Image, @{
            Name = 'Status'
            Expression = {
                switch ($_.State) { 2 { 'running' } 3 { 'exited' } default { "state:$_" } }
            }
        }
}

function Get-SbxList {
    [CmdletBinding()] param([string]$Runtime = (Resolve-SbxRuntime))
    # Explicit if/else, not if-with-return-then-fallthrough: a non-terminating error
    # in the wslc branch used to skip its `return` and drop into the docker branch,
    # which then ran `wslc ps --filter ... --format ...` (flags wslc doesn't have) and
    # spewed parse errors over wslc's usage text. The branches must be exclusive.
    if ($Runtime -eq 'wslc') {
        $global:LASTEXITCODE = 0
        $raw = & $Runtime list --all --format json 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sbx: '$Runtime list' failed (exit $LASTEXITCODE); cannot list sandboxes"
            return
        }
        return ConvertFrom-WslcList -Json $raw
    }
    else {
        $global:LASTEXITCODE = 0
        $lines = & $Runtime ps -a --filter 'label=sbx=1' --format '{{json .}}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sbx: '$Runtime ps' failed (exit $LASTEXITCODE); cannot list sandboxes"
            return
        }
        return ConvertFrom-DockerPs -Lines @($lines)
    }
}

function Get-SbxRemoveVerb {
    param([string]$Runtime)
    if ($Runtime -eq 'wslc') { 'remove' } else { 'rm' }
}

function Remove-SbxContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    $rm = Get-SbxRemoveVerb $Runtime
    # a --rm container may already be gone; both idempotent. Assign stdout to a
    # variable (not just redirect stderr) so the container name doesn't get
    # echoed twice, but still check the exit code so a real runtime failure
    # (daemon down, etc.) surfaces instead of being silently swallowed. An
    # "already gone" failure (Test-SbxBenignRuntimeError) stays silent.
    $global:LASTEXITCODE = 0
    $out = & $Runtime stop $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime stop $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    $global:LASTEXITCODE = 0
    $out = & $Runtime $rm $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime $rm $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
}

function Remove-SbxVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    $verb = if ($Runtime -eq 'wslc') { 'remove' } else { 'rm' }
    $global:LASTEXITCODE = 0
    $out = & $Runtime volume $verb $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime volume $verb $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
}

function Resolve-SbxWindow {
    [CmdletBinding()]
    param([bool]$OnWindows = $IsWindows, [string]$Requested = 'here')
    if ($OnWindows) { return $Requested }
    # Non-Windows: there is no wt.exe backend, so GUI window/tab spawning is
    # unsupported — fall back to (or, for an explicit request, reject in favor of)
    # foreground. `--new-window`/`--window`/`--win` are Windows-only for now.
    if ($Requested -eq 'window') { throw "sbx: --new-window is not supported on this platform (Windows only, for now)" }
    if ($Requested -eq 'tab')    { throw "sbx: --tab is not supported on this platform (foreground only)" }
    return 'here'
}

function Install-SbxShim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$BinDir,
        [bool]$Executable = ($IsMacOS -or $IsLinux)
    )
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Force $BinDir | Out-Null }
    $shim = Join-Path $BinDir 'sbx'
    $body = @(
        '#!/bin/sh'
        '# sbx launcher shim (macOS) — execs the pwsh CLI entry point.'
        "exec pwsh -NoProfile -File `"$RepoDir/sbx-cli.ps1`" `"`$@`""
    ) -join "`n"
    Set-Content -Path $shim -Value $body
    if ($Executable) { & chmod +x $shim }
    return $shim
}

function Get-SbxWorkspacePath {
    [CmdletBinding()]
    param([string]$Override = $env:SBX_WORKSPACE)
    if ($Override) { return $Override }
    return (Join-Path $HOME 'sbx-ws')
}

function Get-SbxSessionName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # tmux rejects '.' and ':' in session names (window/pane addressing syntax).
    return ($Name -replace '[.:]', '-')
}

function Get-SbxVolumeRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Longest mount-root prefix wins: C:\ on Windows; / vs /Volumes/X on macOS.
    # The path need not exist (add validates existence separately).
    $full = [System.IO.Path]::GetFullPath($Path)
    $best = ''
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        $root = $d.RootDirectory.FullName
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and
            $root.Length -gt $best.Length) { $best = $root }
    }
    if (-not $best) { throw "sbx: cannot determine volume for: $Path" }
    return $best
}

function Get-SbxOriginsPath {
    [CmdletBinding()] param()
    # Host-side, OUTSIDE the workspace: the container must not be able to edit
    # where `sbx rm` moves repos back to.
    return (Join-Path $HOME '.sbx/origins.json')
}

function Get-SbxOrigins {
    [CmdletBinding()]
    param([string]$ManifestPath = (Get-SbxOriginsPath))
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return @{} }
    try {
        $parsed = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "sbx: origins manifest at $ManifestPath is corrupt ($($_.Exception.Message)) — fix or delete it, then re-run"
    }
    if ($parsed -is [hashtable]) { return $parsed }
    return @{}
}

function Save-SbxOrigins {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Origins,
          [string]$ManifestPath = (Get-SbxOriginsPath))
    $dir = Split-Path -Parent $ManifestPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $Origins | ConvertTo-Json | Set-Content -LiteralPath $ManifestPath
}

function New-SbxLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LinkPath,
          [Parameter(Mandatory)][string]$TargetPath,
          [bool]$IsWin = $IsWindows)
    # Junction ONLY on Windows (no admin / Developer Mode needed; resolved by
    # NTFS for every local accessor); symlink everywhere else — macOS host AND
    # the Linux container, where self-hosted test runs execute this code and
    # `New-Item -ItemType Junction` silently yields a plain directory. The
    # container never traverses these links either way — it sees the REAL dir
    # in the workspace (FINDINGS 2026-07-22).
    if (-not $IsWin) { $null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop }
    else        { $null = New-Item -ItemType Junction     -Path $LinkPath -Target $TargetPath -ErrorAction Stop }
}

function Stop-SbxSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$Runtime = (Resolve-SbxRuntime))
    # Best-effort: session may not exist, sbx-main may be down, or runtime may be
    # missing from PATH. Never fatal — swallow all errors including CommandNotFoundException.
    try { $null = & $Runtime exec sbx-main tmux kill-session -t (Get-SbxSessionName $Name) 2>$null } catch { }
}

function Add-SbxProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath))
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "sbx: path not found: $Path" }
    $src  = $resolved.Path.TrimEnd('\', '/')
    $item = Get-Item -LiteralPath $src
    if ($item.LinkType) { throw "sbx: $src is already a link — was it added already?" }
    $name = Split-Path -Leaf $src
    if ($name -eq 'hub') { throw "sbx: 'hub' is reserved for the orchestrator session" }
    $dest = Join-Path $WorkspaceDir $name
    if (Test-Path -LiteralPath $dest) { throw "sbx: '$name' already exists in the workspace ($dest)" }
    # Session names are derived from the project name (tmux-hostile chars folded
    # to '-'), so two DIFFERENT project names can collide on the SAME tmux
    # session (e.g. 'foo-bar' and 'foo.bar'). Catch it before we move anything.
    $newSession = Get-SbxSessionName $name
    if (Test-Path -LiteralPath $WorkspaceDir) {
        foreach ($existing in Get-ChildItem -LiteralPath $WorkspaceDir -Directory) {
            if ((Get-SbxSessionName $existing.Name) -eq $newSession) {
                throw "sbx: '$name' collides with existing project '$($existing.Name)' (tmux session '$newSession')"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
        New-Item -ItemType Directory -Force $WorkspaceDir | Out-Null
    }
    if ((Get-SbxVolumeRoot $src) -ne (Get-SbxVolumeRoot $WorkspaceDir)) {
        throw "sbx: $src is on a different volume than the workspace ($WorkspaceDir); a cross-volume add would copy instead of rename — not supported"
    }
    Invoke-SbxOutsidePath -Path @($src) -Action {
        Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
        New-SbxLink -LinkPath $src -TargetPath $dest
    }
    # Manifest write happens ONLY after both the move and the link succeed — a
    # failure in either throws (ErrorAction Stop) before we reach here, so we
    # never record an entry the filesystem doesn't back up.
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $origins[$name] = $src
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
    return [pscustomobject]@{ Name = $name; Workspace = $dest; Origin = $src }
}

function Invoke-SbxOutsidePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path,
          [Parameter(Mandatory)][scriptblock]$Action)
    # PowerShell's FileSystemProvider refuses Move-Item/Remove-Item on an item
    # that is (or contains) the session's current location ("Cannot move item
    # because the item ... is in use") — even on Unix, where a bare rename(2)
    # would succeed. Since `sbx add` is most naturally run from inside the very
    # repo being added, step out to the first path's parent for the duration,
    # then return to the SAME logical path — which, post-move, resolves through
    # the freshly created link, so the caller's location never appears to move.
    $here = (Get-Location).Path
    $sep  = [IO.Path]::DirectorySeparatorChar
    $inside = $false
    foreach ($p in $Path) {
        $full = [IO.Path]::GetFullPath($p)
        if ($here.Equals($full, [StringComparison]::OrdinalIgnoreCase) -or
            $here.StartsWith($full + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            $inside = $true; break
        }
    }
    if (-not $inside) { return (& $Action) }
    Set-Location -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($Path[0])))
    try     { return (& $Action) }
    finally {
        # If the action failed partway the original path may be gone; fall back
        # to the nearest existing ancestor rather than throwing from finally.
        $back = $here
        while ($back -and -not (Test-Path -LiteralPath $back)) { $back = Split-Path -Parent $back }
        if ($back) { Set-Location -LiteralPath $back }
    }
}

function Remove-SbxProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath),
          [string]$Runtime = (Resolve-SbxRuntime))
    $dest = Join-Path $WorkspaceDir $Name
    if (-not (Test-Path -LiteralPath $dest)) { throw "sbx: no project '$Name' in the workspace" }
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $origin  = $origins[$Name]
    if (-not $origin) {
        throw "sbx: no recorded origin for '$Name' — move it back by hand from $dest and reconcile $ManifestPath"
    }
    # SAFETY GATE: the manifest names the move-back target, but the LINK is the
    # proof. Only proceed if the origin path is currently a link pointing at the
    # workspace copy — anything else means the world changed under us.
    $link = Get-Item -LiteralPath $origin -ErrorAction SilentlyContinue
    $wantTarget = (Get-Item -LiteralPath $dest).FullName
    $gotTarget  = if ($link -and $link.LinkType) { @($link.Target)[0] } else { $null }
    if (-not $gotTarget -or
        ([IO.Path]::GetFullPath($gotTarget) -ne [IO.Path]::GetFullPath($wantTarget))) {
        throw "sbx: origin check failed for '$Name': expected $origin to be a link to $dest — refusing to move anything. Reconcile by hand."
    }
    Stop-SbxSession -Name $Name -Runtime $Runtime
    # pwsh 7 Remove-Item on a junction/symlink dir removes the REPARSE POINT only
    # (no recursion into the target) — but never pass -Recurse here.
    # -ErrorAction Stop on both: under default ErrorActionPreference a failed
    # Remove-Item/Move-Item is non-terminating, so execution would otherwise fall
    # through to the manifest write below and manufacture the "no recorded
    # origin" state the safety gate above exists to prevent.
    Invoke-SbxOutsidePath -Path @($dest, $origin) -Action {
        Remove-Item -LiteralPath $origin -Force -ErrorAction Stop
        Move-Item -LiteralPath $dest -Destination $origin -ErrorAction Stop
    }
    $origins.Remove($Name)
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
}

function Build-SbxMainCreateArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth',
          [string]$Name = 'sbx-main',
          [switch]$Posix)
    $ws = ConvertTo-SbxMountPath -HostPath $WorkspacePath -Posix:$Posix
    return @('run','-d','--name',$Name,'--label','sbx=1',
             '-v',"${AuthVolume}:/home/agent/.claude",
             '-v',"${ws}:/work",'-w','/work',
             $Image,'sleep','infinity')
    # Anchor is `sleep infinity`, NOT the tmux server: tmux exits when its last
    # session closes, which would kill the container. Sessions are created on
    # demand through exec (Build-SbxAttachArgs).
}

function Build-SbxAttachArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session,
          [string]$WorkDir = '/work',
          [string]$Name = 'sbx-main')
    # `new-session -A` attaches if the session exists, creates it (running
    # claude) if not — one verb for both cases.
    return @('exec','-it',$Name,'tmux','new-session','-A',
             '-s',$Session,'-c',$WorkDir,
             'claude','--dangerously-skip-permissions')
}

function Build-SbxScratchArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth')
    return @('run','--rm','-i','-t','--name',$Name,'--label','sbx=1',
             '-v',"${AuthVolume}:/home/agent/.claude",
             # Throwaway per-run projects volume: scratch cwd is /work (image
             # WORKDIR), the same history key the hub session uses in the shared
             # auth volume — without this override a scratch /resume menu shows
             # hub and prior-scratch sessions. wslc rejects anonymous volumes
             # (E_INVALIDARG, see FINDINGS), so it's named after the container
             # and reaped in the same best-effort cleanup.
             '-v',"${Name}-proj:/home/agent/.claude/projects",
             $Image,'claude','--dangerously-skip-permissions')
}

function Remove-SbxScratchLeftovers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    Remove-SbxContainer -Name $Name -Runtime $Runtime
    # Volume removal must follow container removal. Remove-SbxVolume tolerates
    # "already gone" but surfaces real runtime failures (Test-SbxBenignRuntimeError).
    Remove-SbxVolume -Name "${Name}-proj" -Runtime $Runtime
}

function Get-SbxMainState {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime), [string]$Name = 'sbx-main')
    $row = @(Get-SbxList -Runtime $Runtime) | Where-Object { $_.Name -eq $Name }
    if (-not $row) { return 'absent' }
    if (@($row)[0].Status -eq 'running') { return 'running' }
    return 'stopped'
}

function Start-SbxMain {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime),
          [string]$WorkspaceDir = (Get-SbxWorkspacePath))
    switch (Get-SbxMainState -Runtime $Runtime) {
        'running' { return }
        'stopped' { $null = & $Runtime start sbx-main; return }
        'absent'  {
            if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
                New-Item -ItemType Directory -Force $WorkspaceDir | Out-Null
            }
            $createArgs = Build-SbxMainCreateArgs -WorkspacePath $WorkspaceDir -Posix:$IsMacOS
            $null = & $Runtime @createArgs
        }
    }
}

function Invoke-SbxRebuild {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime), [switch]$Force)
    if (-not $Force) {
        $answer = Read-Host "sbx: rebuild destroys sbx-main and every running session (workspace and history survive). Continue? [y/N]"
        if ($answer -notmatch '^[Yy]') { return }
    }
    Remove-SbxContainer -Name 'sbx-main' -Runtime $Runtime
    Start-SbxMain -Runtime $Runtime
}

function Stop-SbxMain {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime))
    $null = & $Runtime stop sbx-main 2>$null
}

function Invoke-SbxSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][string]$Operation,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath))
    # c-lite sync (see spec): host-side git with host credentials; the container
    # never holds keys. Exactly these verbs — a wider surface (arbitrary git
    # args) would make this a host-command proxy, which it must never become.
    $allowed = @('push', 'pull', 'fetch')
    if ($Operation -notin $allowed) {
        throw "sbx: sync operation must be one of: $($allowed -join ', ')"
    }
    $dir = Join-Path $WorkspaceDir $Name
    if (-not (Test-Path -LiteralPath $dir)) { throw "sbx: no project '$Name' in the workspace" }
    # Guard against traversal (`sbx sync .. push`): the resolved dir must be a
    # DIRECT CHILD of the workspace, not merely *somewhere under* it.
    if ((Get-Item -LiteralPath $dir).Parent.FullName -ne (Get-Item -LiteralPath $WorkspaceDir).FullName) {
        throw "sbx: no project '$Name' in the workspace"
    }
    & git -C $dir $Operation
}

function Get-SbxLiveSessions {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime))
    if ((Get-SbxMainState -Runtime $Runtime) -ne 'running') { return @() }
    return @(& $Runtime exec sbx-main tmux list-sessions -F '#S' 2>$null | Where-Object { $_ })
}

function Get-SbxProjects {
    [CmdletBinding()]
    param([string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath),
          [string]$Runtime = (Resolve-SbxRuntime))
    if (-not (Test-Path -LiteralPath $WorkspaceDir)) { return }
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $live    = Get-SbxLiveSessions -Runtime $Runtime
    # Dot-dirs are infrastructure, not projects (e.g. the planned /work/.sbx
    # status dir from docs/sbx-agent-status.md) — never list them.
    foreach ($d in (Get-ChildItem -LiteralPath $WorkspaceDir -Directory | Where-Object { $_.Name -notlike '.*' })) {
        [pscustomobject]@{
            Name    = $d.Name
            Origin  = $origins[$d.Name]
            Session = ((Get-SbxSessionName $d.Name) -in $live)
        }
    }
}

function Invoke-SbxStatus {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime),
          [string]$ScriptPath = (Join-Path $PSScriptRoot 'sbx-agent-status.sh'))
    # Fleet oversight cross-check (docs/sbx-agent-status.md): the script needs
    # tmux, which lives inside sbx-main, so pipe it in over exec's stdin — no
    # image change, nothing written to the workspace. Read-only by design: if
    # the container isn't up there is nothing to report, so don't start it.
    if ((Get-SbxMainState -Runtime $Runtime) -ne 'running') {
        return "sbx: sbx-main is not running — nothing to report"
    }
    $execArgs = [System.Collections.Generic.List[string]]::new()
    $execArgs.Add('exec'); $execArgs.Add('-i')
    if ($env:SBX_IDLE_WARN) {
        $execArgs.Add('-e'); $execArgs.Add("SBX_IDLE_WARN=$($env:SBX_IDLE_WARN)")
    }
    $execArgs.Add('sbx-main'); $execArgs.Add('bash'); $execArgs.Add('-s')
    $a = $execArgs.ToArray()
    # The script's output is UTF-8 (tmux pane titles carry claude's glyphs);
    # PowerShell decodes native stdout with [Console]::OutputEncoding, which
    # defaults to the legacy OEM codepage on Windows and mojibakes them
    # (observed: "Γ£│" for "✳"). Pin UTF-8 for the duration of the call.
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        Get-SbxStatusScriptBody -ScriptPath $ScriptPath | & $Runtime @a
    }
    finally { [Console]::OutputEncoding = $prevEnc }
}

function Get-SbxStatusScriptBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath)
    # Two CRLF hazards between here and bash: (1) a Windows checkout can hand
    # us the script with CRLF endings, which bash rejects line by line
    # ($'\r': command not found) — normalize. (2) PowerShell appends a
    # PLATFORM newline (\r\n on Windows) when piping a string into a native
    # command, so bash would see one trailing line containing just \r — end
    # the body with `exit 0` so bash never reads past the real script.
    $body = (Get-Content -LiteralPath $ScriptPath -Raw) -replace "`r`n", "`n"
    return $body.TrimEnd("`n") + "`nexit 0`n"
}
