# sbx macOS Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sbx` run `claude --dangerously-skip-permissions` inside a throwaway Docker container on macOS (Apple Silicon), foreground-only over SSH, keeping the Windows/`wslc` path working from one codebase.

**Architecture:** Single cross-platform PowerShell codebase. The pure builder functions stay shared; OS-specific behavior is injected as explicit parameters (`-Posix`, `-IsMac`, `-Runtime`) so every branch is unit-testable under pwsh on any host. Five seams diverge: container runtime binary, mount-path form, terminal spawn (Windows-only), `ls`/`stop` formatting, and install wiring. One unified image.

**Tech Stack:** PowerShell 7 (`pwsh`), Pester (unit tests), Docker (macOS runtime), `wslc` (Windows runtime), Debian bookworm image + Node LTS + Claude Code.

## Global Constraints

- Runtime resolution: `wslc` on Windows, `docker` on macOS, overridable via `SBX_RUNTIME` env. Copy this precedence verbatim: override → docker(mac) → wslc.
- macOS is **foreground-only**: no window/tab spawning; `--tab` must error; `--here` is a no-op default.
- Docker container-remove verb is `rm`; `wslc`'s is `remove`. Never hardcode one.
- Docker list filter is the label `sbx=1` (already set by `Build-SbxRunArgs`), not a name prefix.
- macOS mount paths are absolute POSIX paths handed to docker verbatim (`/Users/...:/work`). Never emit a `/mnt/...` form.
- Image name `sbx:latest`; auth volume `sbx-claude-auth`; auth mount `/home/agent/.claude`; per-repo projects volume mounted at `/home/agent/.claude/projects`.
- Pure functions must not read the automatic `$IsMacOS`/`$IsWindows` globals directly except at the single top-level entry (`Invoke-Sbx`, `install.ps1` main body); everything else takes the platform as a parameter.
- Tests run with: `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`.
- Git: work on branch `feat/macos-port`; granular commits; do not merge to `main` until the Windows non-regression gate (final section) is satisfied.

---

## Task 1: Prerequisites & initial macOS probe pass (P1, P2, P5)

Empirical, not TDD. Confirms Docker's real behavior on this Mac **before** any code is built on it, and records it in `docs/FINDINGS.md`. The result of P2/P3 decides whether Task 2 (image change) is needed at all.

**Files:**
- Modify: `docs/FINDINGS.md` (append a macOS section)

- [ ] **Step 1: Install pwsh and confirm the runtime**

Run:
```bash
brew install powershell
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'   # expect 7.x
docker version --format '{{.Server.Version}}'          # expect a version, daemon reachable
```
Expected: pwsh 7.x prints; docker server version prints (daemon up).

- [ ] **Step 2: Build the current image on macOS/arm64**

Run:
```bash
cd /Users/user/src/sbx
docker build -t sbx:latest -f Sandboxfile .
docker run --rm sbx:latest claude --version    # expect e.g. "2.1.x (Claude Code)"
```
Expected: image builds on arm64; Claude Code version prints.

- [ ] **Step 3: P1 — bind-mount visibility + writability by `agent`**

Run:
```bash
mkdir -p /tmp/sbx-probe && echo hi > /tmp/sbx-probe/MARKER.txt
docker run --rm -v /tmp/sbx-probe:/work -w /work sbx:latest \
  bash -c 'ls -la /work; id; touch /work/_w && echo WRITE_OK && rm /work/_w'
```
Expected: `MARKER.txt` listed; `id` shows `uid=1000(agent)`; `WRITE_OK` prints. Record the outcome (writable / not) in FINDINGS.

- [ ] **Step 4: P2/P3 — named-volume ownership (the decision gate)**

Run:
```bash
docker volume create sbx-claude-auth >/dev/null
docker run --rm -v sbx-claude-auth:/home/agent/.claude \
  -v sbx-proj-probe:/home/agent/.claude/projects sbx:latest \
  bash -c 'stat -c "%U:%G %n" /home/agent/.claude /home/agent/.claude/projects; \
           su agent -c "touch /home/agent/.claude/_w && echo CLAUDE_WRITE_OK" 2>&1; \
           su agent -c "touch /home/agent/.claude/projects/_w && echo PROJ_WRITE_OK" 2>&1'
docker volume rm sbx-proj-probe >/dev/null
```
Expected: prints owner of each mount. **Decision gate:**
- If both are `agent:agent` and both `*_WRITE_OK` print → Docker's copy-on-init preserved the image's `agent` ownership; **Task 2's image change is NOT needed** — mark Task 2 accordingly.
- If either is `root:root` / write fails → **Task 2's gosu privilege-drop IS needed.**

- [ ] **Step 5: P5 — `docker ps` JSON field shape**

Run:
```bash
docker run -d --name sbx-probe-ls --label sbx=1 sbx:latest sleep 60 >/dev/null
docker ps -a --filter label=sbx=1 --format '{{json .}}'
docker rm -f sbx-probe-ls >/dev/null
```
Expected: one JSON object. **Record the exact keys** present for name/image/state (`Names`, `Image`, `State`, `Status`). Task 5's parser is written against `.State` with a `.Status` fallback — confirm `.State` exists; if not, note the actual field.

- [ ] **Step 6: Record findings and commit**

Append a `## macOS (Docker Desktop <version>, arm64)` section to `docs/FINDINGS.md` capturing P1, P2/P3 (with the decision), and P5 (the field list).

```bash
git add docs/FINDINGS.md
git commit -m "docs(findings): record macOS Docker probe results (P1/P2/P3/P5)"
```

---

## Task 2: Unified privilege-drop image (CONTINGENT on Task 1 P2/P3)

**Only implement if Task 1 Step 4 showed root-owned or unwritable volume mounts.** If the volumes came up `agent:agent`, skip the code change: instead add a one-line note to the FINDINGS macOS section ("Docker copy-on-init preserves image `agent` ownership; no entrypoint privilege-drop needed") and check this task's boxes as N/A.

**Files:**
- Modify: `Sandboxfile` (add `gosu`, remove `USER agent`, rework entrypoint to root→chown→gosu-drop)

**Interfaces:**
- Produces: an `sbx:latest` image whose entrypoint starts as root, chowns `/home/agent/.claude` (covering the nested `projects` volume), performs the `.ssh` copy, then `exec gosu agent "$@"`.

- [ ] **Step 1: Add gosu to the apt install line**

In `Sandboxfile`, add `gosu` to the first `apt-get install` list (alongside `ca-certificates curl git tmux ripgrep openssh-client gnupg`).

- [ ] **Step 2: Replace the entrypoint script and drop `USER agent`**

Replace the entrypoint heredoc so the script is (written to `/usr/local/bin/sbx-entrypoint`, `chmod +x`):

```bash
#!/bin/bash
# Runs as root. Docker named volumes can mount root:root; wslc volumes are already
# agent-owned, so these chowns are harmless no-ops there. Fix ownership, prep ssh,
# then drop to the non-root agent user for the actual command.
chown -R agent:agent /home/agent/.claude 2>/dev/null || true
if [ -d /home/agent/.ssh-ro ]; then
  install -d -o agent -g agent -m 700 /home/agent/.ssh
  cp -r /home/agent/.ssh-ro/. /home/agent/.ssh/ 2>/dev/null || true
  chown -R agent:agent /home/agent/.ssh
  chmod 600 /home/agent/.ssh/id_* 2>/dev/null || true
  [ -f /home/agent/.ssh/known_hosts ] || touch /home/agent/.ssh/known_hosts
  chmod 600 /home/agent/.ssh/known_hosts 2>/dev/null || true
fi
exec gosu agent "$@"
```

Remove the `USER agent` line (the container now starts as root and drops via gosu). Keep `WORKDIR /work`, `ENV CLAUDE_CONFIG_DIR=/home/agent/.claude`, `ENTRYPOINT ["/usr/local/bin/sbx-entrypoint"]`, `CMD ["bash"]`, and the `StrictHostKeyChecking accept-new` line.

- [ ] **Step 3: Rebuild and verify the privilege drop + volume writability**

Run:
```bash
docker build -t sbx:latest -f Sandboxfile .
docker run --rm -v sbx-claude-auth:/home/agent/.claude \
  -v sbx-proj-probe2:/home/agent/.claude/projects sbx:latest \
  bash -c 'id; touch /home/agent/.claude/_w /home/agent/.claude/projects/_w && echo BOTH_WRITE_OK'
docker volume rm sbx-proj-probe2 >/dev/null
```
Expected: `id` shows `uid=1000(agent)` (gosu dropped root); `BOTH_WRITE_OK` prints.

- [ ] **Step 4: Commit**

```bash
git add Sandboxfile
git commit -m "feat(image): root-drop entrypoint via gosu for Docker volume ownership"
```

---

## Task 3: `Resolve-SbxRuntime`

**Files:**
- Modify: `sbx.ps1` (add function near the top)
- Test: `tests/Runtime.Tests.ps1` (create)

**Interfaces:**
- Produces: `Resolve-SbxRuntime([bool]$IsMac = $IsMacOS, [string]$Override = $env:SBX_RUNTIME) -> 'wslc'|'docker'|<override>`

- [ ] **Step 1: Write the failing test**

Create `tests/Runtime.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Resolve-SbxRuntime' {
    It 'returns wslc on Windows' { Resolve-SbxRuntime -IsMac:$false -Override $null | Should -Be 'wslc' }
    It 'returns docker on macOS' { Resolve-SbxRuntime -IsMac:$true  -Override $null | Should -Be 'docker' }
    It 'honors an explicit override' { Resolve-SbxRuntime -IsMac:$true -Override 'podman' | Should -Be 'podman' }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Runtime.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Resolve-SbxRuntime` not recognized.

- [ ] **Step 3: Implement**

Add to `sbx.ps1` (above `Invoke-Sbx`):
```powershell
function Resolve-SbxRuntime {
    [CmdletBinding()]
    param([bool]$IsMac = $IsMacOS, [string]$Override = $env:SBX_RUNTIME)
    if ($Override) { return $Override }
    if ($IsMac)    { return 'docker' }
    return 'wslc'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Runtime.Tests.ps1 -Output Detailed"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Runtime.Tests.ps1
git commit -m "feat: add Resolve-SbxRuntime (wslc/docker/override)"
```

---

## Task 4: Mount-path POSIX branch + `Build-SbxRunArgs -Posix`

**Files:**
- Modify: `sbx.ps1` (`ConvertTo-SbxMountPath`, `Build-SbxRunArgs`)
- Test: `tests/MountPath.Tests.ps1`, `tests/RunArgs.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-SbxMountPath` (existing Windows behavior when `-Posix` absent)
- Produces: `ConvertTo-SbxMountPath([string]$HostPath, [switch]$Posix)` — with `-Posix`, requires an absolute POSIX path and returns it trailing-slash-trimmed, verbatim. `Build-SbxRunArgs(..., [switch]$Posix)` threads `-Posix` to its internal `ConvertTo-SbxMountPath` calls (both `/work` and `--ssh`).

- [ ] **Step 1: Write the failing tests (mount path)**

Append to `tests/MountPath.Tests.ps1`:
```powershell
Describe 'ConvertTo-SbxMountPath -Posix (macOS)' {
    It 'passes an absolute POSIX path through, trimming a trailing slash' {
        ConvertTo-SbxMountPath '/Users/user/src/foo/' -Posix | Should -Be '/Users/user/src/foo'
    }
    It 'returns an already-clean absolute path unchanged' {
        ConvertTo-SbxMountPath '/Users/user/src/foo' -Posix | Should -Be '/Users/user/src/foo'
    }
    It 'throws on a relative path under -Posix' {
        { ConvertTo-SbxMountPath 'src/foo' -Posix } | Should -Throw
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/MountPath.Tests.ps1 -Output Detailed"`
Expected: FAIL — `-Posix` is not a recognized parameter.

- [ ] **Step 3: Implement the `-Posix` branch**

Edit `ConvertTo-SbxMountPath` in `sbx.ps1`:
```powershell
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
    $drive = $matches[1].ToUpper()
    $rest  = $matches[2] -replace '\\', '/'
    return "${drive}:/$rest"
}
```

- [ ] **Step 4: Run to verify mount-path tests pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/MountPath.Tests.ps1 -Output Detailed"`
Expected: PASS (existing 3 Windows tests + new 3 macOS tests).

- [ ] **Step 5: Write failing tests (run args) and guard the Windows-only ssh test**

In `tests/RunArgs.Tests.ps1`, change the existing `'ssh run: ...'` `It` to run only on Windows by adding `-Skip:(-not $IsWindows)` to that `It`. Then append a macOS block:
```powershell
Describe 'Build-SbxRunArgs -Posix (macOS)' {
    It 'mounts a POSIX repo path at /work verbatim and adds the per-repo projects volume' {
        $o = ConvertFrom-SbxArgs @('/Users/user/src/foo')
        $a = Build-SbxRunArgs -Options $o -Name 'sbx-foo-abc123' -Posix
        ($a -join ' ') | Should -BeLike '*-v /Users/user/src/foo:/work*'
        ($a -join ' ') | Should -BeLike '*-w /work*'
        ($a -join ' ') | Should -BeLike '*-v sbx-proj-foo-*:/home/agent/.claude/projects*'
    }
    It 'ssh run mounts ~/.ssh (POSIX) read-only to .ssh-ro' {
        $o = ConvertFrom-SbxArgs @('--ssh','/Users/user/src/foo')
        $a = Build-SbxRunArgs -Options $o -Name 'sbx-foo-abc123' -Posix
        $sshExpected = (ConvertTo-SbxMountPath (Join-Path $HOME '.ssh') -Posix) + ':/home/agent/.ssh-ro:ro'
        ($a -join ' ') | Should -BeLike "*-v $sshExpected*"
        ($a -join ' ') | Should -BeLike '*-v /Users/user/src/foo:/work*'
    }
}
```

- [ ] **Step 6: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/RunArgs.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Build-SbxRunArgs` has no `-Posix` parameter.

- [ ] **Step 7: Thread `-Posix` through `Build-SbxRunArgs`**

Edit `Build-SbxRunArgs` in `sbx.ps1`: add `[switch]$Posix` to `param(...)`, and update the two internal calls:
```powershell
        $src = ConvertTo-SbxMountPath -HostPath $Options.Path -Posix:$Posix
```
```powershell
        $sshSrc = ConvertTo-SbxMountPath -HostPath (Join-Path $HOME '.ssh') -Posix:$Posix
```

- [ ] **Step 8: Run to verify all pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/MountPath.Tests.ps1 tests/RunArgs.Tests.ps1 -Output Detailed"`
Expected: PASS (Windows ssh test skipped on macOS; new macOS tests pass).

- [ ] **Step 9: Commit**

```bash
git add sbx.ps1 tests/MountPath.Tests.ps1 tests/RunArgs.Tests.ps1
git commit -m "feat: POSIX mount-path branch + Build-SbxRunArgs -Posix"
```

---

## Task 5: Docker list parsing + `Get-SbxList` runtime dispatch

**Files:**
- Modify: `sbx.ps1` (`Get-SbxList`; add `ConvertFrom-DockerPs`, `ConvertFrom-WslcList`)
- Test: `tests/List.Tests.ps1` (create)

**Interfaces:**
- Consumes: `Resolve-SbxRuntime` (Task 3)
- Produces: `ConvertFrom-DockerPs([string[]]$Lines) -> objects {Name,Image,Status}`; `ConvertFrom-WslcList([string]$Json) -> objects {Name,Image,Status}`; `Get-SbxList([string]$Runtime = (Resolve-SbxRuntime))` dispatching to the right parser.

- [ ] **Step 1: Write the failing tests**

Create `tests/List.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-DockerPs' {
    It 'maps Names/Image/State into Name/Image/Status (running)' {
        $line = '{"Names":"sbx-foo-abc123","Image":"sbx:latest","State":"running","Status":"Up 2 minutes"}'
        $r = ConvertFrom-DockerPs -Lines @($line)
        $r.Name   | Should -Be 'sbx-foo-abc123'
        $r.Image  | Should -Be 'sbx:latest'
        $r.Status | Should -Be 'running'
    }
    It 'maps an exited container' {
        $line = '{"Names":"sbx-foo-x","Image":"sbx:latest","State":"exited","Status":"Exited (0) 1 min ago"}'
        (ConvertFrom-DockerPs -Lines @($line)).Status | Should -Be 'exited'
    }
    It 'ignores blank lines' {
        ConvertFrom-DockerPs -Lines @('', '') | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-WslcList' {
    It 'filters to sbx-* and maps State int to Status' {
        $json = '[{"Name":"sbx-foo-abc","Image":"sbx:latest","State":2},' +
                '{"Name":"other","Image":"x","State":3}]'
        $r = ConvertFrom-WslcList -Json $json
        @($r).Count | Should -Be 1
        $r.Name     | Should -Be 'sbx-foo-abc'
        $r.Status   | Should -Be 'running'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/List.Tests.ps1 -Output Detailed"`
Expected: FAIL — parsers not defined.

- [ ] **Step 3: Implement the parsers and dispatch**

In `sbx.ps1`, replace `Get-SbxList` with:
```powershell
function ConvertFrom-DockerPs {
    [CmdletBinding()] param([string[]]$Lines)
    foreach ($line in ($Lines | Where-Object { $_ })) {
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
    [CmdletBinding()] param([string]$Json)
    if (-not $Json) { return }
    @($Json | ConvertFrom-Json) |
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
    if ($Runtime -eq 'wslc') {
        return ConvertFrom-WslcList -Json (& $Runtime list --all --format json 2>$null)
    }
    $lines = & $Runtime ps -a --filter 'label=sbx=1' --format '{{json .}}' 2>$null
    return ConvertFrom-DockerPs -Lines @($lines)
}
```

- [ ] **Step 4: Run to verify passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/List.Tests.ps1 -Output Detailed"`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/List.Tests.ps1
git commit -m "feat: docker/wslc list parsers + Get-SbxList runtime dispatch"
```

---

## Task 6: `Resolve-SbxWindow` + `Remove-SbxContainer` helpers

**Files:**
- Modify: `sbx.ps1` (add `Get-SbxRemoveVerb`, `Remove-SbxContainer`, `Resolve-SbxWindow`; rewrite `Stop-Sbx` to use them)
- Test: `tests/Dispatch.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Resolve-SbxRuntime`, `Get-SbxList`
- Produces: `Get-SbxRemoveVerb([string]$Runtime) -> 'remove'|'rm'`; `Remove-SbxContainer([string]$Name, [string]$Runtime)`; `Resolve-SbxWindow([bool]$IsMac, [string]$Requested) -> 'here'|'tab'|'window'` (throws on `tab` under macOS).

- [ ] **Step 1: Write the failing tests**

Append to `tests/Dispatch.Tests.ps1`:
```powershell
Describe 'Get-SbxRemoveVerb' {
    It 'wslc uses remove' { Get-SbxRemoveVerb 'wslc'   | Should -Be 'remove' }
    It 'docker uses rm'   { Get-SbxRemoveVerb 'docker' | Should -Be 'rm' }
    It 'podman uses rm'   { Get-SbxRemoveVerb 'podman' | Should -Be 'rm' }
}

Describe 'Resolve-SbxWindow' {
    It 'forces foreground (here) on macOS regardless of request' {
        Resolve-SbxWindow -IsMac:$true -Requested 'window' | Should -Be 'here'
        Resolve-SbxWindow -IsMac:$true -Requested 'here'   | Should -Be 'here'
    }
    It 'rejects --tab on macOS' {
        { Resolve-SbxWindow -IsMac:$true -Requested 'tab' } | Should -Throw '*tab*'
    }
    It 'passes the request through on Windows' {
        Resolve-SbxWindow -IsMac:$false -Requested 'tab'    | Should -Be 'tab'
        Resolve-SbxWindow -IsMac:$false -Requested 'window' | Should -Be 'window'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Dispatch.Tests.ps1 -Output Detailed"`
Expected: FAIL — helpers not defined.

- [ ] **Step 3: Implement the helpers and rewrite `Stop-Sbx`**

Add to `sbx.ps1`:
```powershell
function Get-SbxRemoveVerb {
    param([string]$Runtime)
    if ($Runtime -eq 'wslc') { 'remove' } else { 'rm' }
}

function Remove-SbxContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    $rm = Get-SbxRemoveVerb $Runtime
    & $Runtime stop $Name 2>$null     # a --rm container may already be gone; both idempotent
    & $Runtime $rm   $Name 2>$null
}

function Resolve-SbxWindow {
    [CmdletBinding()]
    param([bool]$IsMac = $IsMacOS, [string]$Requested = 'window')
    if ($IsMac) {
        if ($Requested -eq 'tab') { throw "sbx: --tab is not supported on macOS (foreground only)" }
        return 'here'
    }
    return $Requested
}
```

Replace `Stop-Sbx` body with:
```powershell
function Stop-Sbx {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    if ($Name -in @('--all', '-a', '*')) {
        foreach ($n in @(Get-SbxList -Runtime $Runtime | ForEach-Object { $_.Name })) {
            Remove-SbxContainer -Name $n -Runtime $Runtime
        }
        return
    }
    Remove-SbxContainer -Name $Name -Runtime $Runtime
}
```

- [ ] **Step 4: Run to verify passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Dispatch.Tests.ps1 -Output Detailed"`
Expected: PASS (existing Dispatch tests + 6 new).

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Dispatch.Tests.ps1
git commit -m "feat: Resolve-SbxWindow + Remove-SbxContainer (per-runtime verb)"
```

---

## Task 7: Wire the runtime + foreground path into `Invoke-Sbx`

Integration task — no new unit test (the pieces are unit-tested; correctness here is verified by the full suite staying green plus a live scratch run).

**Files:**
- Modify: `sbx.ps1` (`Invoke-Sbx`)

**Interfaces:**
- Consumes: `Resolve-SbxRuntime`, `Get-SbxList`, `Stop-Sbx`, `Build-SbxRunArgs -Posix`, `Resolve-SbxWindow`, `Remove-SbxContainer`, `Start-WtSbx` (Windows-only).

- [ ] **Step 1: Rewrite `Invoke-Sbx`**

Replace `Invoke-Sbx` in `sbx.ps1` with:
```powershell
function Invoke-Sbx {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())
    $runtime = Resolve-SbxRuntime
    $o = ConvertFrom-SbxArgs -Arguments $Arguments
    switch ($o.Command) {
        'ls'   { return Get-SbxList -Runtime $runtime }
        'stop' { return Stop-Sbx -Name $o.Target -Runtime $runtime }
    }
    if (-not $o.Scratch) {
        $resolved = Resolve-Path -LiteralPath $o.Path -ErrorAction SilentlyContinue
        if (-not $resolved) { throw "sbx: path not found: $($o.Path)" }
        $o.Path = $resolved.Path
    }
    $name    = Get-SbxContainerName -Path $o.Path -Override $o.Name
    $runArgs = Build-SbxRunArgs -Options $o -Name $name -Posix:$IsMacOS
    $window  = Resolve-SbxWindow -IsMac:$IsMacOS -Requested $o.Window
    switch ($window) {
        'here'  { try { & $runtime @runArgs } finally { Remove-SbxContainer -Name $name -Runtime $runtime } }
        'tab'   { Start-WtSbx -RunArgs $runArgs -Name $name -NewTab }
        default { Start-WtSbx -RunArgs $runArgs -Name $name }
    }
}
```
(Note: `Start-WtSbx` remains Windows/`wslc`-only and is never reached on macOS because `Resolve-SbxWindow` forces `here`. It intentionally keeps its literal `wslc` calls.)

- [ ] **Step 2: Run the full suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
Expected: PASS — all Describe blocks green (Windows-only `It`s skipped on macOS).

- [ ] **Step 3: Live scratch smoke test**

Run:
```bash
pwsh -NoProfile -File sbx-cli.ps1 --here
```
Inside the container, run `id` (expect `agent`), `exit`. Then:
```bash
docker ps -a --filter label=sbx=1   # expect no leftover scratch container (--rm)
```
Expected: scratch container runs foreground and leaves nothing.

- [ ] **Step 4: Commit**

```bash
git add sbx.ps1
git commit -m "feat: runtime-agnostic Invoke-Sbx with macOS foreground path"
```

---

## Task 8: macOS install shim

**Files:**
- Modify: `sbx.ps1` (add `Install-SbxShim`)
- Modify: `install.ps1` (dot-source `sbx.ps1`; add `$IsMacOS` branch)
- Test: `tests/Install.Tests.ps1` (create)

**Interfaces:**
- Produces: `Install-SbxShim([string]$RepoDir, [string]$BinDir) -> <shim path>` — writes an executable `sbx` shim that execs `pwsh -NoProfile -File <RepoDir>/sbx-cli.ps1 "$@"`.

- [ ] **Step 1: Write the failing test**

Create `tests/Install.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Install-SbxShim' {
    It 'writes an executable sbx shim that execs pwsh against sbx-cli.ps1' {
        $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("sbxbin-" + [guid]::NewGuid())
        $shim = Install-SbxShim -RepoDir '/repo/sbx' -BinDir $tmp
        try {
            Test-Path $shim | Should -BeTrue
            (Split-Path -Leaf $shim) | Should -Be 'sbx'
            (Get-Content $shim -Raw) | Should -BeLike '*exec pwsh -NoProfile -File "/repo/sbx/sbx-cli.ps1"*'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Install.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Install-SbxShim` not defined.

- [ ] **Step 3: Implement `Install-SbxShim`**

Add to `sbx.ps1`:
```powershell
function Install-SbxShim {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoDir, [Parameter(Mandatory)][string]$BinDir)
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Force $BinDir | Out-Null }
    $shim = Join-Path $BinDir 'sbx'
    $body = @(
        '#!/bin/sh'
        '# sbx launcher shim (macOS) — execs the pwsh CLI entry point.'
        "exec pwsh -NoProfile -File `"$RepoDir/sbx-cli.ps1`" `"`$@`""
    ) -join "`n"
    Set-Content -Path $shim -Value $body
    if ($IsMacOS -or $IsLinux) { & chmod +x $shim }
    return $shim
}
```

- [ ] **Step 4: Run to verify passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Install.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Add the macOS branch to `install.ps1`**

At the top of `install.ps1`, after `$ErrorActionPreference = 'Stop'`, add dot-sourcing and the branch (the `$repo` line already exists below — move/compute it before this branch):
```powershell
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$repo/sbx.ps1"

if ($IsMacOS) {
    $bin  = Join-Path $HOME '.local/bin'
    $shim = Install-SbxShim -RepoDir $repo -BinDir $bin
    Write-Host "Installed sbx shim at $shim"
    if (($env:PATH -split ':') -notcontains $bin) {
        Write-Host "NOTE: $bin is not on your PATH. Add:  export PATH=`"$bin`:`$PATH`""
    }
    Write-Host "Open a new shell, then try:  sbx <path>   (or: sbx --here <path>)"
    return
}
# --- Windows wiring below (unchanged) ---
```
Ensure the existing Windows body no longer redeclares `$repo` (remove the duplicate `$repo = ...` line further down if present).

- [ ] **Step 6: Verify the installer end-to-end (macOS)**

Run:
```bash
pwsh -NoProfile -File install.ps1
ls -l ~/.local/bin/sbx
~/.local/bin/sbx ls    # should run (empty list or current containers), proving the shim execs pwsh
```
Expected: shim created and executable; `sbx ls` runs.

- [ ] **Step 7: Commit**

```bash
git add sbx.ps1 install.ps1 tests/Install.Tests.ps1
git commit -m "feat(install): macOS sbx shim into ~/.local/bin"
```

---

## Task 9: End-to-end macOS verification + checklist

**Files:**
- Modify: `verify/CHECKLIST.md` (append a macOS section)
- Modify: `docs/FINDINGS.md` (finalize `--ssh` result P4)

- [ ] **Step 1: Live isolation / scratch / auth run-through**

With a real repo path `<repo>` on this Mac:
```bash
sbx --here <repo>     # (or: sbx <repo>) — foreground
```
Inside verify: `/work` shows the repo; `git -C /work status` clean (no dubious-ownership, no false-modified flood); `touch /work/_w && rm /work/_w` succeeds; a *different* host repo path is absent. Exit; confirm `sbx ls` shows no leftover. Re-run and confirm Claude is already logged in (auth volume). Confirm `claude --resume` in `<repo>` does not list another repo's sessions.

- [ ] **Step 2: P4 — `--ssh` against the NAS remote**

```bash
sbx --ssh --here <a-nas-repo>
```
Inside: `stat -c %A ~/.ssh/id_*` → `-rw-------`; `git ls-remote origin` (or the NAS `ssh://…@the NAS/…` URL) succeeds. Then run a **default** `sbx --here <a-nas-repo>` (no `--ssh`) and confirm `~/.ssh-ro` is absent and an SSH git op fails on the missing key.

- [ ] **Step 3: Record P4 in FINDINGS and append the macOS checklist**

Add the P4 result to the `docs/FINDINGS.md` macOS section. Append to `verify/CHECKLIST.md`:
```markdown
## macOS (Docker) notes
- Runtime is `docker`; `sbx` is foreground-only (no window/tab). Concurrency = multiple
  Termius/tmux sessions, each running `sbx`.
- Section 2 leftover check: `docker ps -a --filter label=sbx=1` (not `wslc list`).
- Section 3 (two side-by-side WT windows) is Windows-only; on macOS run each repo in its
  own terminal/tmux pane instead.
- `--tab`/`--window` are rejected on macOS.
```

- [ ] **Step 4: Commit**

```bash
git add verify/CHECKLIST.md docs/FINDINGS.md
git commit -m "docs: macOS verification checklist + --ssh finding (P4)"
```

---

## Task 10: Docs — README & CLAUDE.md

**Files:**
- Modify: `README.md` (macOS install/usage block)
- Modify: `CLAUDE.md` (widen conventions to name docker/macOS)

- [ ] **Step 1: Add a macOS block to `README.md`**

Under Install, add:
```markdown
### macOS (Docker)

    brew install powershell                       # pwsh runtime for the launcher
    docker build -t sbx:latest -f Sandboxfile .   # build the image (once)
    docker volume create sbx-claude-auth          # auth volume (once)
    # log in once — see docs/LOGIN.md
    pwsh -NoProfile -File install.ps1             # drops an `sbx` shim into ~/.local/bin
    # ensure ~/.local/bin is on your PATH, then open a new shell

macOS is **foreground-only** (no new-window/tab): `sbx <path>` runs Claude in the current
terminal. Run several by opening several terminal/tmux sessions. `--tab`/`--window` are not
supported; `--here` is the default. Set `SBX_RUNTIME` to use podman/colima/orbstack.
```

- [ ] **Step 2: Widen `CLAUDE.md` conventions**

In `CLAUDE.md`, update Build/run and Conventions so they name both platforms — e.g. runtime is `wslc` on Windows / `docker` on macOS (overridable via `SBX_RUNTIME`); launcher logic is PowerShell 7 using native Windows paths on Windows and absolute POSIX paths on macOS. Keep the closing `Now say: "I've reviewed the project memory."` line last.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: macOS install/usage + cross-platform conventions"
```

---

## Windows non-regression gate (before merging to `main`)

The image change (Task 2, if applied) and the shared `Invoke-Sbx`/`Stop-Sbx` refactor touch the Windows path. **On a Windows machine**, before merging:

- [ ] `wslc build -t sbx:latest -f Sandboxfile .` succeeds; a run drops to `agent` (gosu) and the auth volume is still writable.
- [ ] `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"` all green (macOS-only `It`s skipped).
- [ ] Re-run `verify/CHECKLIST.md` sections 1–6 on Windows — especially new-window/tab spawn and `sbx ls`/`sbx stop`.
- [ ] Merge `feat/macos-port` to `main` with `--no-ff`; push `main` to `origin`.

---

## Self-review notes

- **Spec coverage:** §1 runtime→Task 3; §1 mount-path→Task 4; §2 image→Task 2 (contingent, per spec's own "rides on Docker behaving as predicted" caveat)→verified by Task 1 probes; §3 command surface→Tasks 6–7, install→Task 8; §4 ls/stop→Tasks 5–6; §5 terminal spawn (Windows-only, foreground on mac)→Tasks 6–7; verification P1–P5→Tasks 1 & 9; docs→Tasks 9–10; Windows non-regression→final gate.
- **Contingency:** Task 2 is explicitly conditional on Task 1 Step 4; if Docker copy-on-init yields agent-owned volumes, the Windows image is left untouched (lower risk).
- **Type consistency:** `Resolve-SbxRuntime`, `Resolve-SbxWindow`, `Get-SbxRemoveVerb`, `Remove-SbxContainer`, `ConvertFrom-DockerPs`, `ConvertFrom-WslcList`, `Install-SbxShim`, and the `-Posix` switch names are used identically across defining and consuming tasks.
