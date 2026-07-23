# sbx v2 — Unified Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-repo sandbox containers with one long-lived `sbx-main` container over a single workspace mount, with live `add`/`rm` of projects (move + junction-back), tmux session-per-project, and host-side `sync`.

**Architecture:** One host workspace dir (`~/sbx-ws`) mounted at `/work` in one persistent container anchored by `sleep infinity`; tmux sessions (one per project + `hub`) reached via `runtime exec -it … tmux new-session -A`. `sbx add` renames the repo into the workspace and leaves a junction (Windows) / symlink (macOS) at the origin; origins are tracked in a host-side manifest (`~/.sbx/origins.json`) and verified against the link before `rm` moves anything back. No SSH keys in the container; `sbx sync` runs git host-side.

**Tech Stack:** PowerShell 7 (`sbx.ps1`, dot-sourced pure builder functions), Pester 5 unit tests, `wslc` (Windows) / `docker` via OrbStack (macOS).

**Spec:** `docs/superpowers/specs/2026-07-22-sbx-unified-workspace-design.md` — read it first.

## Global Constraints

- Branch: `feat/unified-workspace` (already created off `feat/macos-port`). Granular commits; a coupled change that would leave a non-building intermediate goes in ONE commit.
- All launcher logic in `sbx.ps1` as pure builder functions + thin effectful wrappers, PowerShell 7. Windows paths native (`C:\…`), macOS absolute POSIX.
- Mount source form: forward-slash Windows drive-letter path via existing `ConvertTo-SbxMountPath` (NEVER `/mnt/c`; see `docs/FINDINGS.md`).
- Container/image names: container `sbx-main`, image `sbx:latest`, auth volume `sbx-claude-auth`. Workspace default `$HOME/sbx-ws`, env override `SBX_WORKSPACE`.
- Runtime: `Resolve-SbxRuntime` (wslc on Windows, docker on macOS, `SBX_RUNTIME` override). WT window/tab spawning is Windows-only and hardcodes `wslc` (unchanged v1 behavior).
- Unit tests: `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"` must be green at every commit. Platform-gate live-runtime/junction tests with `-Skip:(-not $IsWindows)` / `-Skip:(-not $IsMacOS)` as the existing suites do.
- The `Sandboxfile` image is NOT modified in this plan.
- Do not commit `docs/superpowers/plans/*` checkbox updates mixed into code commits; plan-file check-offs ride along with the task's commit.

---

### Task 1: Runtime probes — `exec -it` TTY, `start` verb (GATE)

The whole attach model rests on two unverified wslc verbs. Probe before building. **If either fails, STOP and report back to the user — the design needs revisiting.** (docker/OrbStack equivalents are standard and known-good; no macOS probe needed now.)

**Files:**
- Modify: `docs/FINDINGS.md` (append a section)

**Interfaces:**
- Produces: empirical go/no-go for `wslc exec -it <c> tmux new-session -A -s <s> -c <dir> <cmd>` and `wslc start <c>`. Later tasks assume both work.

- [ ] **Step 1: Start an anchored container**

Run (PowerShell):
```powershell
wslc run -d --name sbx-probe-main -v sbx-claude-auth:/home/agent/.claude sbx:latest sleep infinity
```
Expected: container id line; `wslc list --all --format json` shows `sbx-probe-main` with `State:2`.

- [ ] **Step 2: Interactive tmux attach through exec**

Run **interactively in a real terminal** (needs a human eyeball on the TTY):
```powershell
wslc exec -it sbx-probe-main tmux new-session -A -s probe -c /tmp bash
```
Expected: a tmux status bar appears, shell cwd is `/tmp`. Inside, run `touch /tmp/probe-marker`, then detach (`Ctrl-b d`). Re-run the same command: same session (marker shell history / `ls /tmp/probe-marker` exists). Detach again, `exit` is NOT required.

- [ ] **Step 3: Stop/start cycle**

```powershell
wslc stop sbx-probe-main
wslc start sbx-probe-main
wslc exec sbx-probe-main sh -c "echo alive"
```
Expected: `start` is a valid verb and `alive` prints. (tmux sessions do NOT survive the cycle — that's expected and fine.)

- [ ] **Step 4: Clean up**

```powershell
wslc stop sbx-probe-main 2>$null; wslc remove sbx-probe-main
```

- [ ] **Step 5: Record findings**

Append to `docs/FINDINGS.md` a section `## wslc exec -it / start (unified-workspace probes, 2.9.4.0)` recording: exact commands, whether the TTY attach was fully interactive (colors, resize, Ctrl-b handled), whether `start` exists, any quirks verbatim.

- [ ] **Step 6: Commit**

```bash
git add docs/FINDINGS.md
git commit -m "docs(findings): probe wslc exec -it TTY attach and start verb"
```

---

### Task 2: Workspace path + name helpers

**Files:**
- Modify: `sbx.ps1` (append functions)
- Create: `tests/Workspace.Tests.ps1`

**Interfaces:**
- Produces: `Get-SbxWorkspacePath([string]$Override = $env:SBX_WORKSPACE) -> string`; `Get-SbxSessionName([string]$Name) -> string` (tmux-safe: `.` and `:` replaced with `-`).

- [ ] **Step 1: Write failing tests**

Create `tests/Workspace.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxWorkspacePath' {
    It 'defaults to $HOME/sbx-ws' {
        Get-SbxWorkspacePath -Override $null | Should -Be (Join-Path $HOME 'sbx-ws')
    }
    It 'honors the SBX_WORKSPACE override' {
        Get-SbxWorkspacePath -Override 'C:\elsewhere\ws' | Should -Be 'C:\elsewhere\ws'
    }
}

Describe 'Get-SbxSessionName' {
    It 'passes simple names through' { Get-SbxSessionName 'foo' | Should -Be 'foo' }
    It 'replaces tmux-hostile . and : with -' {
        Get-SbxSessionName 'foo.bar' | Should -Be 'foo-bar'
        Get-SbxSessionName 'a:b.c'  | Should -Be 'a-b-c'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Workspace.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-SbxWorkspacePath` not recognized.

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
```

- [ ] **Step 4: Run to verify pass** — same command, expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Workspace.Tests.ps1
git commit -m "feat: workspace path + tmux session name helpers"
```

---

### Task 3: Same-volume guard

`sbx add` must be a rename, never a silent cross-volume copy.

**Files:**
- Modify: `sbx.ps1`
- Test: `tests/Workspace.Tests.ps1` (append)

**Interfaces:**
- Produces: `Get-SbxVolumeRoot([string]$Path) -> string` (longest-prefix mount root via `[System.IO.DriveInfo]`; works for `C:\` on Windows and `/` / `/Volumes/X` on macOS).

- [ ] **Step 1: Append failing tests to `tests/Workspace.Tests.ps1`**

```powershell
Describe 'Get-SbxVolumeRoot' {
    It 'returns the drive root on Windows' -Skip:(-not $IsWindows) {
        Get-SbxVolumeRoot 'C:\Users\user\src\foo' | Should -Be 'C:\'
    }
    It 'is equal for two paths on the same volume' {
        (Get-SbxVolumeRoot $HOME) | Should -Be (Get-SbxVolumeRoot (Join-Path $HOME 'anything'))
    }
    It 'resolves a relative path against cwd before matching' {
        { Get-SbxVolumeRoot 'relative\path' } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run to verify failure** — `Invoke-Pester tests/Workspace.Tests.ps1`: FAIL, function not recognized.

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
```

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Workspace.Tests.ps1
git commit -m "feat: same-volume guard helper for workspace moves"
```

---

### Task 4: Origins manifest

Host-side state (outside the workspace — invisible/untamperable from the container) mapping project name → original host path.

**Files:**
- Modify: `sbx.ps1`
- Test: `tests/Workspace.Tests.ps1` (append)

**Interfaces:**
- Produces: `Get-SbxOriginsPath() -> string` (`$HOME/.sbx/origins.json`); `Get-SbxOrigins([string]$ManifestPath) -> hashtable`; `Save-SbxOrigins([hashtable]$Origins, [string]$ManifestPath)`. All later tasks pass `-ManifestPath` explicitly in tests (TestDrive).

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'Sbx origins manifest' {
    It 'returns an empty hashtable when the manifest does not exist' {
        $m = Get-SbxOrigins -ManifestPath (Join-Path $TestDrive 'nope.json')
        $m | Should -BeOfType [hashtable]
        $m.Count | Should -Be 0
    }
    It 'round-trips a mapping (creating parent dirs)' {
        $p = Join-Path $TestDrive 'deep\origins.json'
        Save-SbxOrigins -Origins @{ foo = 'C:\src\foo' } -ManifestPath $p
        (Get-SbxOrigins -ManifestPath $p)['foo'] | Should -Be 'C:\src\foo'
    }
    It 'default path lives under $HOME/.sbx' {
        Get-SbxOriginsPath | Should -Be (Join-Path $HOME '.sbx/origins.json')
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
    $parsed = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
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
```

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Workspace.Tests.ps1
git commit -m "feat: host-side origins manifest for workspace projects"
```

---

### Task 5: `Add-SbxProject` / `Remove-SbxProject` (move + link-back)

The heart of live add/remove. Real filesystem round-trip tests on `$TestDrive` (same volume by construction).

**Files:**
- Modify: `sbx.ps1`
- Test: `tests/Workspace.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-SbxVolumeRoot`, `Get-SbxOrigins`/`Save-SbxOrigins`, `Get-SbxSessionName` (Tasks 2–4).
- Produces: `New-SbxLink($LinkPath, $TargetPath, [bool]$IsMac)`; `Add-SbxProject([string]$Path, [string]$WorkspaceDir, [string]$ManifestPath) -> pscustomobject{Name,Workspace,Origin}`; `Remove-SbxProject([string]$Name, [string]$WorkspaceDir, [string]$ManifestPath, [string]$Runtime)`; `Stop-SbxSession([string]$Name, [string]$Runtime)` (best-effort tmux kill, mockable).

- [ ] **Step 1: Append failing tests**

```powershell
Describe 'Add-SbxProject / Remove-SbxProject' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:src = Join-Path $TestDrive 'origin\myrepo'
        $script:man = Join-Path $TestDrive 'origins.json'
        New-Item -ItemType Directory -Force $script:src | Out-Null
        Set-Content (Join-Path $script:src 'FILE.txt') 'hello'
        Mock -CommandName Stop-SbxSession -MockWith { }
    }
    It 'moves the repo into the workspace and leaves a link at the origin' {
        $expectedOrigin = (Resolve-Path -LiteralPath $script:src).Path
        $r = Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man
        $r.Name | Should -Be 'myrepo'
        Get-Content (Join-Path $script:ws 'myrepo\FILE.txt') | Should -Be 'hello'
        (Get-Item -LiteralPath $script:src).LinkType |
            Should -BeIn @('Junction','SymbolicLink')          # junction on Win, symlink on mac
        Get-Content (Join-Path $script:src 'FILE.txt') | Should -Be 'hello'   # host view via link
        (Get-SbxOrigins -ManifestPath $script:man)['myrepo'] | Should -Be $expectedOrigin
    }
    It 'refuses to add the same name twice' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $TestDrive 'other\myrepo') | Out-Null
        { Add-SbxProject -Path (Join-Path $TestDrive 'other\myrepo') -WorkspaceDir $script:ws -ManifestPath $script:man } |
            Should -Throw '*already exists*'
    }
    It 'refuses to add a path that is already a link' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        { Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man } |
            Should -Throw '*already a link*'
    }
    It 'rm reverses add exactly: real dir back at origin, link gone, manifest entry gone' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
        (Get-Item -LiteralPath $script:src).LinkType | Should -BeNullOrEmpty   # real dir again
        Get-Content (Join-Path $script:src 'FILE.txt') | Should -Be 'hello'
        Test-Path (Join-Path $script:ws 'myrepo') | Should -BeFalse
        (Get-SbxOrigins -ManifestPath $script:man).ContainsKey('myrepo') | Should -BeFalse
        Should -Invoke Stop-SbxSession -Times 1
    }
    It 'rm refuses when the origin link does not point at the workspace copy' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        Remove-Item -LiteralPath $script:src -Force            # delete the link
        New-Item -ItemType Directory -Force $script:src | Out-Null   # impostor real dir
        { Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc' } |
            Should -Throw '*origin*'
    }
    It 'rm throws for an unknown project' {
        { Remove-SbxProject -Name 'ghost' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc' } |
            Should -Throw '*no project*'
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
function New-SbxLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LinkPath,
          [Parameter(Mandatory)][string]$TargetPath,
          [bool]$IsMac = $IsMacOS)
    # Junction on Windows (no admin / Developer Mode needed; resolved by NTFS for
    # every local accessor). Symlink on macOS. Container-side both are broken by
    # design — the container sees the REAL dir in the workspace (FINDINGS 2026-07-22).
    if ($IsMac) { $null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath }
    else        { $null = New-Item -ItemType Junction     -Path $LinkPath -Target $TargetPath }
}

function Stop-SbxSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$Runtime = (Resolve-SbxRuntime))
    # Best-effort: session may not exist, sbx-main may be down. Never fatal.
    $null = & $Runtime exec sbx-main tmux kill-session -t (Get-SbxSessionName $Name) 2>$null
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
    $dest = Join-Path $WorkspaceDir $name
    if (Test-Path -LiteralPath $dest) { throw "sbx: '$name' already exists in the workspace ($dest)" }
    if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
        New-Item -ItemType Directory -Force $WorkspaceDir | Out-Null
    }
    if ((Get-SbxVolumeRoot $src) -ne (Get-SbxVolumeRoot $WorkspaceDir)) {
        throw "sbx: $src is on a different volume than the workspace ($WorkspaceDir); a cross-volume add would copy instead of rename — not supported"
    }
    Move-Item -LiteralPath $src -Destination $dest
    New-SbxLink -LinkPath $src -TargetPath $dest
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $origins[$name] = $src
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
    return [pscustomobject]@{ Name = $name; Workspace = $dest; Origin = $src }
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
    Remove-Item -LiteralPath $origin -Force
    Move-Item -LiteralPath $dest -Destination $origin
    $origins.Remove($Name)
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
}
```

- [ ] **Step 4: Run to verify pass** — `Invoke-Pester tests/Workspace.Tests.ps1`: all green.

- [ ] **Step 5: Run the FULL suite** (`Invoke-Pester tests`) — old suites still green (nothing removed yet).

- [ ] **Step 6: Commit**

```bash
git add sbx.ps1 tests/Workspace.Tests.ps1
git commit -m "feat: live add/rm of workspace projects (move + junction-back, origin-verified)"
```

---

### Task 6: Container-args builders (`sbx-main` create, attach, scratch)

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/Main.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-SbxMountPath` (existing).
- Produces: `Build-SbxMainCreateArgs([string]$WorkspacePath, [string]$Image='sbx:latest', [string]$AuthVolume='sbx-claude-auth', [string]$Name='sbx-main', [switch]$Posix) -> string[]`; `Build-SbxAttachArgs([string]$Session, [string]$WorkDir='/work', [string]$Name='sbx-main') -> string[]`; `Build-SbxScratchArgs([string]$Name, [string]$Image='sbx:latest', [string]$AuthVolume='sbx-claude-auth') -> string[]`.

- [ ] **Step 1: Write failing tests** — create `tests/Main.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Build-SbxMainCreateArgs' {
    It 'creates a detached sbx-main with exactly the workspace and auth mounts' {
        $a = Build-SbxMainCreateArgs -WorkspacePath 'C:\Users\user\sbx-ws'
        ($a -join ' ') | Should -BeLike 'run -d --name sbx-main*'
        ($a -join ' ') | Should -BeLike '*--label sbx=1*'
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        ($a -join ' ') | Should -BeLike '*-v C:/Users/user/sbx-ws:/work*'
        ($a -join ' ') | Should -BeLike '*-w /work*'
        (@($a) | Where-Object { $_ -eq '-v' }).Count | Should -Be 2      # exactly two mounts
        $a[-2..-1] | Should -Be @('sleep','infinity')                     # anchor process
        ($a -join ' ') | Should -Not -BeLike '*--rm*'                     # persistent
        ($a -join ' ') | Should -Not -BeLike '*.ssh*'                     # never keys
    }
    It 'passes a POSIX workspace path through verbatim with -Posix' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/user/sbx-ws' -Posix
        ($a -join ' ') | Should -BeLike '*-v /Users/user/sbx-ws:/work*'
    }
}

Describe 'Build-SbxAttachArgs' {
    It 'execs an attach-or-create tmux session running claude' {
        $a = Build-SbxAttachArgs -Session 'foo' -WorkDir '/work/foo'
        $a | Should -Be @('exec','-it','sbx-main','tmux','new-session','-A',
                          '-s','foo','-c','/work/foo',
                          'claude','--dangerously-skip-permissions')
    }
    It 'defaults to the hub vantage at /work' {
        $a = Build-SbxAttachArgs -Session 'hub'
        ($a -join ' ') | Should -BeLike '*-s hub -c /work claude*'
    }
}

Describe 'Build-SbxScratchArgs' {
    It 'is a --rm throwaway with only the auth volume, running claude' {
        $a = Build-SbxScratchArgs -Name 'sbx-scratch-abc123'
        ($a -join ' ') | Should -BeLike 'run --rm*--name sbx-scratch-abc123*'
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        (@($a) | Where-Object { $_ -eq '-v' }).Count | Should -Be 1
        ($a -join ' ') | Should -Not -BeLike '*:/work*'
        $a[-2..-1] | Should -Be @('claude','--dangerously-skip-permissions')
    }
}
```

- [ ] **Step 2: Run to verify failure** — `Invoke-Pester tests/Main.Tests.ps1`.

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
             $Image,'claude','--dangerously-skip-permissions')
}
```

- [ ] **Step 4: Run to verify pass**, then full suite.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Main.Tests.ps1
git commit -m "feat: sbx-main create / tmux attach / scratch arg builders"
```

---

### Task 7: `sbx-main` lifecycle (state, ensure-running, rebuild, stop)

**Files:**
- Modify: `sbx.ps1`
- Test: `tests/Main.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-SbxList` (existing — both wslc/docker branches return `Name`/`Status` rows and sbx-main matches its filters), `Build-SbxMainCreateArgs`, `Remove-SbxContainer` (existing).
- Produces: `Get-SbxMainState([string]$Runtime) -> 'running'|'stopped'|'absent'`; `Start-SbxMain([string]$Runtime, [string]$WorkspaceDir)`; `Invoke-SbxRebuild([string]$Runtime, [switch]$Force)`; `Stop-SbxMain([string]$Runtime)`.

- [ ] **Step 1: Append failing tests to `tests/Main.Tests.ps1`** (mock-based, Windows-gated where they mock `wslc`):

```powershell
Describe 'Get-SbxMainState' {
    It 'absent when no sbx-main row' {
        Mock -CommandName Get-SbxList -MockWith { @() }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'absent'
    }
    It 'running / stopped from the Status field' {
        Mock -CommandName Get-SbxList -MockWith { @([pscustomobject]@{ Name='sbx-main'; Status='running' }) }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'running'
        Mock -CommandName Get-SbxList -MockWith { @([pscustomobject]@{ Name='sbx-main'; Status='exited' }) }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'stopped'
    }
}

Describe 'Start-SbxMain' -Skip:(-not $IsWindows) {
    It 'no-ops when already running' {
        Mock -CommandName Get-SbxMainState -MockWith { 'running' }
        Mock -CommandName wslc -MockWith { throw 'should not be called' }
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir (Join-Path $TestDrive 'ws')
    }
    It 'starts a stopped container' {
        Mock -CommandName Get-SbxMainState -MockWith { 'stopped' }
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir (Join-Path $TestDrive 'ws')
        $script:calls | Should -Contain 'start sbx-main'
    }
    It 'creates when absent, creating the workspace dir first' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        $ws = Join-Path $TestDrive 'fresh-ws'
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir $ws
        Test-Path $ws | Should -BeTrue
        ($script:calls -join '|') | Should -BeLike '*run -d --name sbx-main*sleep infinity*'
    }
}

Describe 'Invoke-SbxRebuild / Stop-SbxMain' -Skip:(-not $IsWindows) {
    It 'rebuild -Force removes then recreates without prompting' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        Mock -CommandName Read-Host -MockWith { throw 'must not prompt with -Force' }
        Invoke-SbxRebuild -Runtime 'wslc' -Force
        ($script:calls -join '|') | Should -BeLike '*stop sbx-main*'
        ($script:calls -join '|') | Should -BeLike '*remove sbx-main*'
        ($script:calls -join '|') | Should -BeLike '*run -d --name sbx-main*'
    }
    It 'rebuild aborts on a non-y answer' {
        Mock -CommandName Read-Host -MockWith { 'n' }
        Mock -CommandName wslc -MockWith { throw 'should not touch the runtime' }
        Invoke-SbxRebuild -Runtime 'wslc'
    }
    It 'stop stops the container (but does not remove it)' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Stop-SbxMain -Runtime 'wslc'
        $script:calls | Should -Contain 'stop sbx-main'
        ($script:calls -join '|') | Should -Not -BeLike '*remove*'
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
```

- [ ] **Step 4: Run to verify pass**, then full suite.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Main.Tests.ps1
git commit -m "feat: sbx-main lifecycle — state, ensure-running, rebuild, stop"
```

---

### Task 8: `sbx sync` (host-side git)

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/Sync.Tests.ps1`

**Interfaces:**
- Produces: `Invoke-SbxSync([string]$Name, [string]$Operation, [string]$WorkspaceDir) -> git output`. Allowlist: `push`, `pull`, `fetch` — nothing else, ever (c-lite contract from the spec).

- [ ] **Step 1: Write failing tests** — create `tests/Sync.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Invoke-SbxSync' {
    BeforeEach {
        $script:ws = Join-Path $TestDrive 'ws'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'foo') | Out-Null
    }
    It 'runs the allowlisted git op in the project workspace dir' {
        Mock -CommandName git -MockWith { $script:seen = $args }
        Invoke-SbxSync -Name 'foo' -Operation 'push' -WorkspaceDir $script:ws
        ($script:seen -join ' ') | Should -Be "-C $(Join-Path $script:ws 'foo') push"
    }
    It 'rejects a non-allowlisted operation' {
        Mock -CommandName git -MockWith { throw 'must not run' }
        { Invoke-SbxSync -Name 'foo' -Operation 'push --force' -WorkspaceDir $script:ws } | Should -Throw '*one of*'
        { Invoke-SbxSync -Name 'foo' -Operation 'status'       -WorkspaceDir $script:ws } | Should -Throw '*one of*'
    }
    It 'throws for a project not in the workspace' {
        { Invoke-SbxSync -Name 'ghost' -Operation 'push' -WorkspaceDir $script:ws } | Should -Throw '*no project*'
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
    & git -C $dir $Operation
}
```

- [ ] **Step 4: Run to verify pass**, then full suite.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Sync.Tests.ps1
git commit -m "feat: sbx sync — host-side allowlisted git for workspace projects"
```

---

### Task 9: `sbx ls` v2 (projects + origins + live sessions)

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/Projects.Tests.ps1`

**Interfaces:**
- Consumes: `Get-SbxOrigins`, `Get-SbxSessionName`, `Get-SbxMainState`.
- Produces: `Get-SbxLiveSessions([string]$Runtime) -> string[]`; `Get-SbxProjects([string]$WorkspaceDir, [string]$ManifestPath, [string]$Runtime) -> pscustomobject{Name,Origin,Session}[]`.

- [ ] **Step 1: Write failing tests** — create `tests/Projects.Tests.ps1`:

```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxLiveSessions' {
    It 'returns empty when sbx-main is not running' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        @(Get-SbxLiveSessions -Runtime 'wslc').Count | Should -Be 0
    }
}

Describe 'Get-SbxProjects' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:man = Join-Path $TestDrive 'origins.json'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'foo') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'bar.baz') | Out-Null
        Save-SbxOrigins -Origins @{ 'foo' = 'C:\src\foo'; 'bar.baz' = 'C:\src\bar.baz' } -ManifestPath $script:man
    }
    It 'lists workspace dirs with origin and live-session flag' {
        Mock -CommandName Get-SbxLiveSessions -MockWith { @('foo', 'hub') }
        $r = Get-SbxProjects -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
        @($r).Count | Should -Be 2
        ($r | Where-Object Name -eq 'foo').Origin  | Should -Be 'C:\src\foo'
        ($r | Where-Object Name -eq 'foo').Session | Should -BeTrue
        ($r | Where-Object Name -eq 'bar.baz').Session | Should -BeFalse   # sanitized name not live
    }
    It 'returns nothing for a missing workspace dir' {
        Get-SbxProjects -WorkspaceDir (Join-Path $TestDrive 'nope') -ManifestPath $script:man -Runtime 'wslc' |
            Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement in `sbx.ps1`**

```powershell
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
    foreach ($d in Get-ChildItem -LiteralPath $WorkspaceDir -Directory) {
        [pscustomobject]@{
            Name    = $d.Name
            Origin  = $origins[$d.Name]
            Session = ((Get-SbxSessionName $d.Name) -in $live)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**, then full suite.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Projects.Tests.ps1
git commit -m "feat: sbx ls v2 — workspace projects with origins and live sessions"
```

---

### Task 10: Parser v2 + dispatch rewrite + v1 retirement (SINGLE COMMIT)

The grammar flip (`sbx <bareword>` = session, not path) and dispatch rewire are coupled with removing v1 paths — splitting would leave non-building intermediates, so this is one commit (per project convention).

**Files:**
- Modify: `sbx.ps1` — replace `ConvertFrom-SbxArgs`, replace `Invoke-Sbx`, generalize `Start-WtSbx` (make `-Name` cleanup optional as it already is; body unchanged), DELETE `Build-SbxRunArgs`, `Get-SbxProjectVolumeName`, `Stop-Sbx`.
- Modify: `tests/Parser.Tests.ps1` (rewrite), `tests/Dispatch.Tests.ps1` (rewrite), `tests/Subcommands.Tests.ps1` (drop `Stop-Sbx` Describe; keep `Get-SbxList`).
- Delete: `tests/RunArgs.Tests.ps1` (`Build-SbxRunArgs`/`Get-SbxProjectVolumeName` are gone; scratch/attach builders are covered in `tests/Main.Tests.ps1`).

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces: `ConvertFrom-SbxArgs -> pscustomobject{Command('attach'|'add'|'rm'|'sync'|'ls'|'rebuild'|'stop'|'scratch'), Target, Operation, Window}`; `Invoke-Sbx` (alias `sbx`) dispatching per the spec's command table. `--ssh` and `--name` no longer exist (unknown-option error). `sbx <path-looking-arg>` errors with a pointer to `sbx add`.

- [ ] **Step 1: Rewrite `tests/Parser.Tests.ps1`**

```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-SbxArgs (v2)' {
    It 'no args = attach to the hub' {
        $o = ConvertFrom-SbxArgs @()
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -BeNullOrEmpty
        $o.Window  | Should -Be 'window'
    }
    It 'bare name = attach to that project session' {
        $o = ConvertFrom-SbxArgs @('foo')
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -Be 'foo'
    }
    It 'a path-looking arg errors with a pointer to add' {
        { ConvertFrom-SbxArgs @('C:\src\foo') } | Should -Throw '*sbx add*'
        { ConvertFrom-SbxArgs @('src/foo') }    | Should -Throw '*sbx add*'
    }
    It 'parses add <path>' {
        $o = ConvertFrom-SbxArgs @('add', 'C:\src\foo')
        $o.Command | Should -Be 'add'
        $o.Target  | Should -Be 'C:\src\foo'
    }
    It 'parses rm <name>' {
        $o = ConvertFrom-SbxArgs @('rm', 'foo')
        $o.Command | Should -Be 'rm'
        $o.Target  | Should -Be 'foo'
    }
    It 'parses sync <name> <op>' {
        $o = ConvertFrom-SbxArgs @('sync', 'foo', 'push')
        $o.Command   | Should -Be 'sync'
        $o.Target    | Should -Be 'foo'
        $o.Operation | Should -Be 'push'
    }
    It 'parses ls / rebuild / stop / scratch' {
        (ConvertFrom-SbxArgs @('ls')).Command      | Should -Be 'ls'
        (ConvertFrom-SbxArgs @('rebuild')).Command | Should -Be 'rebuild'
        (ConvertFrom-SbxArgs @('stop')).Command    | Should -Be 'stop'
        (ConvertFrom-SbxArgs @('scratch')).Command | Should -Be 'scratch'
    }
    It 'parses --here and --tab wherever they appear' {
        (ConvertFrom-SbxArgs @('--here')).Window          | Should -Be 'here'
        (ConvertFrom-SbxArgs @('foo', '--tab')).Window    | Should -Be 'tab'
        (ConvertFrom-SbxArgs @('--here', 'scratch')).Window | Should -Be 'here'
    }
    It 'errors on missing subcommand arguments' {
        { ConvertFrom-SbxArgs @('add') }          | Should -Throw '*add*'
        { ConvertFrom-SbxArgs @('rm') }           | Should -Throw '*rm*'
        { ConvertFrom-SbxArgs @('sync', 'foo') }  | Should -Throw '*sync*'
    }
    It 'retired v1 flags are unknown options' {
        { ConvertFrom-SbxArgs @('--ssh', 'foo') }        | Should -Throw '*Unknown option*'
        { ConvertFrom-SbxArgs @('--name', 'x', 'foo') }  | Should -Throw '*Unknown option*'
    }
}
```

- [ ] **Step 2: Run to verify failure** (new grammar not implemented).

- [ ] **Step 3: Replace `ConvertFrom-SbxArgs` in `sbx.ps1`**

```powershell
function ConvertFrom-SbxArgs {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $opts = [ordered]@{ Command = 'attach'; Target = $null; Operation = $null; Window = 'window' }
    $positional = [System.Collections.Generic.List[string]]::new()

    foreach ($arg in $Arguments) {
        switch ($arg) {
            '--here' { $opts.Window = 'here' }
            '--tab'  { $opts.Window = 'tab' }
            default  {
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
            $opts.Command = 'rm'; $opts.Target = $positional[1]
        }
        'sync' {
            if ($positional.Count -lt 3) { throw "sbx: 'sync' expects <name> <push|pull|fetch>" }
            $opts.Command = 'sync'; $opts.Target = $positional[1]; $opts.Operation = $positional[2]
        }
        'ls'      { $opts.Command = 'ls' }
        'rebuild' { $opts.Command = 'rebuild' }
        'stop'    { $opts.Command = 'stop' }
        'scratch' { $opts.Command = 'scratch' }
        default {
            if ($positional[0] -match '[\\/]') {
                throw "sbx: '$($positional[0])' looks like a path — v2 takes project names; run 'sbx add <path>' once, then 'sbx <name>'"
            }
            $opts.Command = 'attach'; $opts.Target = $positional[0]
        }
    }
    return [pscustomobject]$opts
}
```

- [ ] **Step 4: Replace `Invoke-Sbx`; delete `Build-SbxRunArgs`, `Get-SbxProjectVolumeName`, `Stop-Sbx`**

```powershell
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
        'scratch' {
            $name    = Get-SbxContainerName -Path $null
            $runArgs = Build-SbxScratchArgs -Name $name
            $window  = Resolve-SbxWindow -IsMac:$IsMacOS -Requested $o.Window
            switch ($window) {
                'here'  { try { & $runtime @runArgs } finally { Remove-SbxContainer -Name $name -Runtime $runtime } }
                'tab'   { Start-WtSbx -RunArgs $runArgs -Name $name -NewTab }
                default { Start-WtSbx -RunArgs $runArgs -Name $name }
            }
            return
        }
        'attach' {
            Start-SbxMain -Runtime $runtime
            if ($o.Target) {
                $projectDir = Join-Path (Get-SbxWorkspacePath) $o.Target
                if (-not (Test-Path -LiteralPath $projectDir)) {
                    throw "sbx: no project '$($o.Target)' in the workspace — 'sbx add <path>' first (or 'sbx ls')"
                }
                $session = Get-SbxSessionName $o.Target
                $workdir = "/work/$($o.Target)"
            }
            else { $session = 'hub'; $workdir = '/work' }
            $attachArgs = Build-SbxAttachArgs -Session $session -WorkDir $workdir
            $window = Resolve-SbxWindow -IsMac:$IsMacOS -Requested $o.Window
            switch ($window) {
                'here'  { & $runtime @attachArgs }        # persistent container: no cleanup
                'tab'   { Start-WtSbx -RunArgs $attachArgs -NewTab }
                default { Start-WtSbx -RunArgs $attachArgs }
            }
            return
        }
    }
}
```

`Start-WtSbx` needs no code change: called without `-Name` it already skips the stop/remove cleanup (attach must NOT reap `sbx-main`); scratch still passes `-Name` for cleanup. Verify this by reading the function, don't take the plan's word for it.

- [ ] **Step 5: Rewrite `tests/Dispatch.Tests.ps1`**

```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# Windows-only: mocks the `wslc` runtime and asserts WT spawning (both Windows-only).
Describe 'Invoke-Sbx dispatch (v2)' -Skip:(-not $IsWindows) {
    BeforeEach {
        Mock -CommandName Start-SbxMain -MockWith { }
        Mock -CommandName Get-SbxWorkspacePath -MockWith { Join-Path $TestDrive 'ws' }
        New-Item -ItemType Directory -Force (Join-Path $TestDrive 'ws\foo') | Out-Null
    }
    It 'sbx foo --here ensures sbx-main then execs the tmux attach in-process' {
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @('foo', '--here')
        Should -Invoke Start-SbxMain -Times 1
        ($script:seen -join ' ') | Should -Be 'exec -it sbx-main tmux new-session -A -s foo -c /work/foo claude --dangerously-skip-permissions'
    }
    It 'sbx (no args) --here attaches the hub at /work' {
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @('--here')
        ($script:seen -join ' ') | Should -BeLike '*-s hub -c /work claude*'
    }
    It 'sbx foo (default) spawns a NEW WT window with the encoded attach, no cleanup' {
        Mock -CommandName Start-Process -MockWith { $script:file = "$FilePath"; $script:wt = $ArgumentList }
        Mock -CommandName wslc -MockWith { throw 'should not run in-process' }
        Invoke-Sbx @('foo')
        $script:file | Should -Be 'wt.exe'
        $script:wt   | Should -Contain '-1'
        $ix = [array]::IndexOf($script:wt, '-EncodedCommand')
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:wt[$ix + 1]))
        $decoded | Should -BeLike '*& wslc @a*'
        $decoded | Should -BeLike "*'exec'*'sbx-main'*"
        $decoded | Should -Not -BeLike '*finally*'      # never reap the persistent container
    }
    It 'sbx ghost throws when the project is not in the workspace' {
        { Invoke-Sbx @('ghost', '--here') } | Should -Throw '*no project*'
    }
    It 'scratch --here runs --rm with cleanup and no /work' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Invoke-Sbx @('scratch', '--here')
        ($script:calls -join '|') | Should -BeLike '*run --rm*'
        ($script:calls -join '|') | Should -Not -BeLike '*:/work*'
        ($script:calls -join '|') | Should -BeLike '*stop sbx-scratch-*'
    }
    It 'add / rm / sync / ls / rebuild / stop route to their handlers' {
        Mock -CommandName Add-SbxProject    -MockWith { }
        Mock -CommandName Remove-SbxProject -MockWith { }
        Mock -CommandName Invoke-SbxSync    -MockWith { }
        Mock -CommandName Get-SbxProjects   -MockWith { }
        Mock -CommandName Invoke-SbxRebuild -MockWith { }
        Mock -CommandName Stop-SbxMain      -MockWith { }
        Invoke-Sbx @('add', 'C:\src\foo');  Should -Invoke Add-SbxProject    -Times 1
        Invoke-Sbx @('rm', 'foo');          Should -Invoke Remove-SbxProject -Times 1
        Invoke-Sbx @('sync', 'foo', 'push'); Should -Invoke Invoke-SbxSync   -Times 1
        Invoke-Sbx @('ls');                 Should -Invoke Get-SbxProjects   -Times 1
        Invoke-Sbx @('rebuild');            Should -Invoke Invoke-SbxRebuild -Times 1
        Invoke-Sbx @('stop');               Should -Invoke Stop-SbxMain      -Times 1
    }
}

Describe 'Get-SbxRemoveVerb' {
    It 'wslc uses remove' { Get-SbxRemoveVerb 'wslc'   | Should -Be 'remove' }
    It 'docker uses rm'   { Get-SbxRemoveVerb 'docker' | Should -Be 'rm' }
}

Describe 'Resolve-SbxWindow' {
    It 'forces here on macOS and rejects --tab' {
        Resolve-SbxWindow -IsMac:$true -Requested 'window' | Should -Be 'here'
        { Resolve-SbxWindow -IsMac:$true -Requested 'tab' } | Should -Throw '*tab*'
    }
    It 'passes the request through on Windows' {
        Resolve-SbxWindow -IsMac:$false -Requested 'tab' | Should -Be 'tab'
    }
}
```

- [ ] **Step 6: Update `tests/Subcommands.Tests.ps1`** — delete the `Describe 'Stop-Sbx'` block entirely; keep `Describe 'Get-SbxList'` unchanged. Delete `tests/RunArgs.Tests.ps1`.

- [ ] **Step 7: Run the FULL suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
Expected: ALL green. Grep for stragglers: `grep -rn "Build-SbxRunArgs\|Get-SbxProjectVolumeName\|Stop-Sbx " sbx.ps1 tests/ sbx-cli.ps1` → only `Stop-SbxMain`/`Stop-SbxSession` hits, no dead references.

- [ ] **Step 8: Commit (single, coupled)**

```bash
git add sbx.ps1 tests/Parser.Tests.ps1 tests/Dispatch.Tests.ps1 tests/Subcommands.Tests.ps1
git rm tests/RunArgs.Tests.ps1
git commit -m "feat!: v2 grammar + dispatch — unified workspace replaces per-repo containers"
```

---

### Task 11: Docs + volume reap

**Files:**
- Modify: `README.md`, `CLAUDE.md`, `verify/CHECKLIST.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Rewrite `verify/CHECKLIST.md`** with the spec's integration checklist, as runnable steps:

```markdown
# sbx v2 verification checklist (manual, live runtime)

Run on Windows (wslc) unless marked; re-run the mirrored items on macOS.

1. **Live add:** with `sbx` (hub) already open: `sbx add ~/src/<some-repo>`;
   in the hub session `ls /work/<name>` shows it IMMEDIATELY (no restart).
   Host-side: `Get-Item ~/src/<some-repo>` shows LinkType Junction and
   `git -C ~/src/<some-repo> status` works through the link.
2. **Session:** `sbx <name>` opens a WT window attached to tmux session
   `<name>` cwd `/work/<name>` running claude. `sbx ls` shows Session=True.
3. **History isolation:** run claude briefly in two projects; `claude --resume`
   in each lists only its own sessions.
4. **rm:** `sbx rm <name>` → repo back at origin as a REAL dir, link gone,
   tmux session gone, `sbx ls` no longer lists it.
5. **rebuild:** `sbx rebuild` → container replaced; workspace intact; step-3
   histories still resumable; login still valid (no re-auth).
6. **Blast radius:** in the hub: `ls /home/agent/.ssh` absent; `/work` shows
   only added projects; no `C:` anywhere.
7. **sync:** `sbx sync <name> fetch` (NAS-remoted repo) succeeds host-side;
   `git fetch` INSIDE the container fails (no keys) — confirming c-lite.
8. **scratch:** `sbx scratch --here` → throwaway, `--rm` cleanup verified via
   `sbx ls` after exit; no `/work` inside.
9. **Concurrency:** windows on `foo` + hub simultaneously; hub edits a file in
   `/work/foo`, project session sees it instantly.
10. **wslc 15-mount ceiling re-check (2.9.4.0):** after the runs above, note
    whether the "Too many volumes (limit: 15)" error still occurs on repeated
    scratch launches; update docs/FINDINGS.md either way.
```

- [ ] **Step 2: Update `README.md`** — rewrite usage sections for the v2 surface (add/rm/attach/ls/sync/rebuild/stop/scratch table from the spec, workspace + junction-back explanation, "agents commit, human pushes" sync model, one-time setup unchanged: build image + create auth volume). Update `CLAUDE.md`: Build/run section unchanged; conventions section — replace the per-repo volume bullet with the unified-workspace model (workspace at `~/sbx-ws`, origins manifest at `~/.sbx/origins.json`, histories live in the shared auth volume keyed by `/work/<name>`); bump wslc version note to 2.9.4.0 (findings file covers both).

- [ ] **Step 3: Reap orphaned per-repo volumes**

```powershell
wslc volume list
# for each sbx-proj-* row:
wslc volume remove <name>
```
Expected: only `sbx-claude-auth` (and any non-sbx volumes) remain.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md verify/CHECKLIST.md
git commit -m "docs: v2 unified-workspace usage, conventions, verification checklist"
```

---

### Task 12: Live verification + findings (human-in-the-loop)

**Files:**
- Modify: `docs/FINDINGS.md` (as discovered), `verify/CHECKLIST.md` (check-offs if desired)

- [ ] **Step 1:** Run `verify/CHECKLIST.md` items 1–10 on Windows with the user driving (interactive TTY steps need a human).
- [ ] **Step 2:** Record any new wslc quirks (esp. item 10, the ceiling re-check) in `docs/FINDINGS.md`.
- [ ] **Step 3:** Commit findings; then use superpowers:finishing-a-development-branch (merge `feat/unified-workspace` → `main` with `--no-ff` per convention; macOS checklist re-run can follow on the Mac).

---

## Self-review notes (already applied)

- Spec coverage: core model → T5/T6/T7; command surface → T10; sync c-lite → T8; state/volumes → T6 (two mounts) + T11 (reap); platform mapping → `New-SbxLink`/`-Posix` switches; migration → T10/T11; testing → per-task + T12. The c-heavy SSH callback and `add --clone` are explicitly out of scope (spec).
- Type consistency: `Command`/`Target`/`Operation`/`Window` fields consistent across parser, dispatch, and tests; `Get-SbxSessionName` used in both `Stop-SbxSession` and `Get-SbxProjects`.
- Gate: Task 1 can invalidate the attach model (`exec -it`); nothing after it is worth building until it passes.
