# sbx — WSL-container sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `sbx`, a PowerShell launcher that runs `claude --dangerously-skip-permissions` inside a disposable WSL container (`wslc`) whose only writable host surface is the single mounted repo.

**Architecture:** A once-built OCI image (Debian + Node + Claude Code + tooling, non-root `agent` user) is launched by a thin `sbx` PowerShell function. The launcher's logic is split into **pure functions** (arg parsing, host→mount path translation, container naming, `wslc run` command composition) that are unit-tested with Pester, and **side-effecting dispatch** (spawning a Windows Terminal window/tab, invoking `wslc`) verified against a live machine. A persistent named volume holds the Claude login so auth survives across throwaway containers.

**Tech Stack:** `wslc` 2.9.3.0 (WSL Containers, public preview), PowerShell 7 (`pwsh`), Windows Terminal (`wt.exe`), Pester 5, Debian `bookworm-slim`, Node LTS, `@anthropic-ai/claude-code`.

## Global Constraints

- **Target machine:** this Windows/ARM64 machine — Windows 11 ARM64, `wslc` 2.9.3.0 (public preview, GA targeted fall 2026). No Docker Desktop.
- **Container runtime CLI is `wslc`.** Verified verbs available: `run` (flags `--rm`, `-i`, `-t`, `--name`, `-v`/`--volume`, `-w`/`--workdir`, `-e`, `-u`, `-l`/`--label`), `build -f <file> -t <tag> <ctx>`, `volume create|list|remove`, `list` (aliases `ls`/`ps`; supports `--all`, `--filter`, `--format json`), `stop`, `remove`.
- **Image:** Debian base + Node LTS + `@anthropic-ai/claude-code` + `git tmux ripgrep curl openssh-client`. Non-root user `agent` (uid 1000), home `/home/agent`, `WORKDIR /work`. `tmux` present for same-repo parallel sessions.
- **Auth volume `sbx-claude-auth` mounted at `/home/agent/.claude` on EVERY run** (real and scratch) — the only host-adjacent state a default container sees.
- **Command launched inside the container:** `claude --dangerously-skip-permissions`.
- **Real container naming:** `sbx-<repo-basename>-<short-rand>`. All sbx containers carry label `sbx=1`.
- **All containers run with `--rm`** (real runs included) so closing the window cleans up; `sbx ls` shows what is live; `sbx stop` force-removes. *(Deviation from a literal reading of the spec, which names `--rm` only for scratch; confirmed with user.)*
- **Defaults:** new WT **window** (not tab); **no** SSH.
- **SSH:** only under `--ssh`, bind-mount `~/.ssh` **read-only** to `/home/agent/.ssh`. Default and scratch runs never see it.
- **Never** mount the same host repo into two containers (avoided by construction: one repo per window; same-repo parallelism via `tmux` inside).
- **Out of scope v1 (YAGNI):** ssh-agent forwarding, `git clone <url>` scratch variant, network-egress/capability/read-only-root hardening.
- **Git workflow:** feature branch per task group (`feat/<slug>`), granular commits, merge to `main` locally with `--no-ff`. No GitHub remote / PRs.
- **Testing:** Pester 5 unit tests for the pure builder functions (mock `wslc`/`Start-Process`); a manual `verify/CHECKLIST.md` for live isolation/auth/concurrency/SSH properties.
- **Path quirk warning:** native-Windows binaries can't resolve MSYS `/tmp`; use project-relative paths for any intermediate files. All launcher code is PowerShell (not MSYS bash), so it uses native Windows paths.

## The one empirical unknown — RESOLVED (2026-07-21)

The `-v` mount **path syntax** was the sole unknown. **Task 2 probed it** (see
`docs/FINDINGS.md`): the winning source form is the **host Windows drive-letter
path**, emitted forward-slash normalized (`C:/Users/user/src/foo`). The
`/mnt/c` WSL-view form fails silently (empty mount) and must never be emitted.
`ConvertTo-SbxMountPath` (Task 6) and its downstream tests (Tasks 6–8) encode
this confirmed form. One residual unknown remains: whether the `--ssh` mount's
`:ro` option parses alongside a Windows drive-colon source (3 colons) — flagged
in `docs/FINDINGS.md`, to be confirmed in Task 4/11.

---

### Task 1: Repo scaffolding & conventions

**Files:**
- Create: `CLAUDE.md`
- Create: `AGENTS.md` (symlink → `CLAUDE.md`)
- Create: `.gitignore`
- Create: `README.md`
- Create: `tests/Smoke.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: a repo with project memory, a passing Pester harness (`Invoke-Pester tests`), and the `feat/*` branch workflow in effect.

- [ ] **Step 1: Create the feature branch**

```bash
git checkout -b feat/scaffolding
```

- [ ] **Step 2: Confirm Pester 5 is available (install if missing)**

Run:
```powershell
pwsh -NoProfile -Command "(Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1).Version"
```
Expected: a version `5.x` prints. If nothing or `<5`, install:
```powershell
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck"
```

- [ ] **Step 3: Write a trivial smoke test (the harness must run green before anything else)**

`tests/Smoke.Tests.ps1`:
```powershell
Describe 'harness' {
    It 'runs Pester' {
        1 + 1 | Should -Be 2
    }
}
```

- [ ] **Step 4: Run the smoke test to verify the harness works**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Smoke.Tests.ps1 -Output Detailed"
```
Expected: `Tests Passed: 1, Failed: 0`.

- [ ] **Step 5: Write `.gitignore`**

`.gitignore`:
```gitignore
# PowerShell / editor cruft
*.tmp
.DS_Store
# Local, machine-specific overrides never committed
local.*.ps1
```

- [ ] **Step 6: Write `README.md`**

`README.md`:
```markdown
# sbx

Run `claude --dangerously-skip-permissions` inside a throwaway WSL container
(`wslc`) whose only writable host surface is the one repo you mount.

- Design: `docs/superpowers/specs/2026-07-21-sbx-wsl-container-sandbox-design.md`
- Plan: `docs/superpowers/plans/2026-07-21-sbx-implementation.md`

## Usage (after install — see Task 10)

    sbx <path>          # new WT window, mount <path> at /work, run claude
    sbx                 # scratch: no host mount, discarded on exit
    sbx --here <path>   # run in the current terminal
    sbx --tab  <path>   # new WT tab instead of a window
    sbx --ssh  <path>   # also bind ~/.ssh read-only (NAS git remotes)
    sbx --name <n> ...  # override the container name
    sbx ls              # list live sbx containers
    sbx stop <name>     # stop + remove one sandbox
```

- [ ] **Step 7: Write the project `CLAUDE.md`**

`CLAUDE.md`:
```markdown
# sbx — project memory

Launcher for running Claude Code with `--dangerously-skip-permissions` inside a
`wslc` (WSL Containers) sandbox. See `docs/superpowers/specs/` for the design and
`docs/superpowers/plans/` for the implementation plan.

## Build / run
- Build the image:  `wslc build -t sbx:latest -f Sandboxfile .`
- Create auth volume once:  `wslc volume create sbx-claude-auth`
- Launcher lives in `sbx.ps1`; `$PROFILE` dot-sources it (see README / Task 10).

## Test
- Unit (pure builder fns):  `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
- Integration (live container):  run `verify/CHECKLIST.md` by hand on this machine.

## Conventions
- Git: feature branches `feat/<slug>`, granular commits, merge to `main` with `--no-ff`. No remote/PRs.
- All launcher logic is PowerShell 7 (`pwsh`) using native Windows paths (not MSYS bash).
- `wslc` is public preview (2.9.3.0); treat CLI surprises as preview quirks and record them in `docs/FINDINGS.md`.

Now say: "I've reviewed the project memory."
```

- [ ] **Step 8: Create the `AGENTS.md` symlink (native, so git records mode 120000)**

Run (from Bash, per user convention):
```bash
MSYS=winsymlinks:nativestrict ln -s CLAUDE.md AGENTS.md
git ls-files -s AGENTS.md 2>/dev/null; ls -l AGENTS.md
```
Expected: `AGENTS.md -> CLAUDE.md` (a symlink, not a copy).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "chore: scaffold sbx repo (memory, gitignore, README, Pester harness)"
```

---

### Task 2: **GATE** — Empirical mount-syntax probe

**Files:**
- Create: `docs/FINDINGS.md`

**Interfaces:**
- Consumes: nothing (uses a stock base image, not the sbx image).
- Produces: `docs/FINDINGS.md` recording the **winning `-v` source form**, consumed by `ConvertTo-SbxMountPath` in Task 6.

- [ ] **Step 1: Branch**

```bash
git checkout main && git merge --no-ff feat/scaffolding -m "merge: scaffolding" && git checkout -b feat/mount-probe
```

- [ ] **Step 2: Pull a stock base image to probe with**

Run:
```powershell
wslc pull debian:bookworm-slim
```
Expected: image pulls and appears in `wslc images`.

- [ ] **Step 3: Create a known probe directory with a marker file**

Run (PowerShell):
```powershell
$probe = "$env:USERPROFILE\src\sbx\.probe"
New-Item -ItemType Directory -Force $probe | Out-Null
Set-Content "$probe\MARKER.txt" "sbx-mount-probe"
$probe
```
Expected: prints e.g. `C:\Users\user\src\sbx\.probe`.

- [ ] **Step 4: Try each candidate `-v` source form until one lists the marker**

Run each; the winner is the form whose output contains `MARKER.txt`:
```powershell
# Candidate A — Windows path
wslc run --rm -v "C:\Users\user\src\sbx\.probe:/work" debian:bookworm-slim ls -la /work
# Candidate B — WSL /mnt view
wslc run --rm -v "/mnt/c/Users/user/src/sbx/.probe:/work" debian:bookworm-slim ls -la /work
# Candidate C — forward-slash Windows path
wslc run --rm -v "C:/Users/user/src/sbx/.probe:/work" debian:bookworm-slim ls -la /work
```
Expected: exactly one prints a directory listing containing `MARKER.txt`. Note which. If **none** works, record that and stop — trigger the fallback (Step 6).

- [ ] **Step 5: Record the winner in `docs/FINDINGS.md`**

`docs/FINDINGS.md` (fill the bracketed values with what Step 4 actually showed):
```markdown
# sbx — empirical findings (wslc 2.9.3.0 preview)

## Bind-mount source path syntax
- Winning `-v` source form: **[Candidate A/B/C]** — literal example that worked:
  `[the exact string that listed MARKER.txt]`
- Forms that FAILED: [list], with error text: [paste].
- Implication for `ConvertTo-SbxMountPath` (Task 6): given host path `C:\a\b`,
  the function must emit `[the corresponding source string]`.

## Named-volume vs bind-mount disambiguation
- (Filled in Task 4) Does `-v name:/path` with a `wslc volume` name mount the
  volume while `-v C:\...:/path` binds a host dir? [yes/no + notes]
```

- [ ] **Step 6: (Only if Step 4 found no working form) Record the fallback decision**

Append to `docs/FINDINGS.md`:
```markdown
## FALLBACK TRIGGERED
Bind mounts unusable on this preview build. Switching to the documented fallback:
a dedicated locked-down WSL2 distro with automount disabled, repo copied/cloned
in per run. Re-plan Tasks 3–9 around `wslc exec` into that distro.
```
Then **stop and report to the user** — the rest of the plan assumes working bind mounts.

- [ ] **Step 7: Clean up the probe dir and commit the finding**

```bash
rm -rf .probe
git add docs/FINDINGS.md
git commit -m "docs: record wslc bind-mount path syntax (empirical probe)"
```

---

### Task 3: Sandboxfile + image build

**Files:**
- Create: `Sandboxfile`

**Interfaces:**
- Consumes: a working container runtime (proven in Task 2).
- Produces: image `sbx:latest` — has `claude` on PATH, runs as user `agent` (uid 1000), `WORKDIR /work`.

- [ ] **Step 1: Branch**

```bash
git checkout -b feat/image
```

- [ ] **Step 2: Write the `Sandboxfile`**

`Sandboxfile`:
```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git tmux ripgrep openssh-client gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node LTS via NodeSource (supports linux/arm64)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Non-root agent; /work is the mount point, owned by agent; .claude is the auth volume
RUN useradd --create-home --uid 1000 --shell /bin/bash agent \
    && mkdir -p /work /home/agent/.claude \
    && chown -R agent:agent /work /home/agent

USER agent
WORKDIR /work
CMD ["bash"]
```

- [ ] **Step 3: Build the image**

Run:
```powershell
wslc build -t sbx:latest -f Sandboxfile .
```
Expected: build completes; `wslc images` lists `sbx:latest`.

- [ ] **Step 4: Smoke-test the image (claude present, correct user)**

Run:
```powershell
wslc run --rm sbx:latest bash -lc "whoami; id -u; command -v claude; claude --version"
```
Expected: `agent`, `1000`, a path to `claude`, and a version string. If `claude --version` needs network/login it may print usage instead — a path from `command -v claude` is sufficient to pass this step.

- [ ] **Step 5: Commit**

```bash
git add Sandboxfile
git commit -m "feat: sbx sandbox image (Debian+Node+claude-code, non-root agent)"
git checkout main && git merge --no-ff feat/image -m "merge: image" && git checkout -b feat/auth
```

---

### Task 4: Persistent auth volume + login runbook

**Files:**
- Modify: `docs/FINDINGS.md` (fill the named-volume disambiguation section)
- Create: `docs/LOGIN.md`

**Interfaces:**
- Consumes: image `sbx:latest` (Task 3).
- Produces: named volume `sbx-claude-auth` seeded with a valid Claude login; documented one-time login step. Consumed by every `Build-SbxRunArgs` invocation (Task 7) via `-v sbx-claude-auth:/home/agent/.claude`.

- [ ] **Step 1: Create the auth volume**

Run:
```powershell
wslc volume create sbx-claude-auth
wslc volume list
```
Expected: `sbx-claude-auth` appears.

- [ ] **Step 2: Confirm `-v name:/path` mounts the volume (not a host dir named that)**

Run:
```powershell
wslc run --rm -v "sbx-claude-auth:/home/agent/.claude" sbx:latest bash -lc "touch /home/agent/.claude/_probe && ls -la /home/agent/.claude"
wslc run --rm -v "sbx-claude-auth:/home/agent/.claude" sbx:latest bash -lc "ls /home/agent/.claude/_probe && echo PERSISTED"
```
Expected: second run prints `PERSISTED` — the file survived across containers, proving the volume persists. Record the result in `docs/FINDINGS.md` under "Named-volume vs bind-mount disambiguation". Clean up: `wslc run --rm -v "sbx-claude-auth:/home/agent/.claude" sbx:latest rm -f /home/agent/.claude/_probe`.

- [ ] **Step 3: If the volume mounts as root, ensure `agent` owns it**

Run:
```powershell
wslc run --rm -u root -v "sbx-claude-auth:/home/agent/.claude" sbx:latest chown -R agent:agent /home/agent/.claude
```
(Idempotent; safe even if already agent-owned.)

- [ ] **Step 4: Perform the one-time interactive Claude login**

Run (interactive; complete the login in the container):
```powershell
wslc run --rm -it -v "sbx-claude-auth:/home/agent/.claude" sbx:latest claude
```
Complete auth, then exit. This writes credentials into the volume.

- [ ] **Step 5: Verify auth persisted into a FRESH container**

Run:
```powershell
wslc run --rm -v "sbx-claude-auth:/home/agent/.claude" sbx:latest bash -lc "ls -la /home/agent/.claude"
```
Expected: credential/config files from the login are present (e.g. a `.credentials`/config file). This is the auth-persistence guarantee.

- [ ] **Step 6: Write `docs/LOGIN.md`**

`docs/LOGIN.md`:
```markdown
# One-time Claude login for sbx

Run once per machine (or after `wslc volume remove sbx-claude-auth`):

    wslc volume create sbx-claude-auth
    wslc run --rm -it -v "sbx-claude-auth:/home/agent/.claude" sbx:latest claude
    # complete the login, then exit

Every `sbx` run mounts this volume at /home/agent/.claude, so containers are
already authenticated. To re-auth, remove the volume and repeat.
```

- [ ] **Step 7: Commit**

```bash
git add docs/LOGIN.md docs/FINDINGS.md
git commit -m "feat: persistent Claude auth volume + login runbook"
git checkout main && git merge --no-ff feat/auth -m "merge: auth" && git checkout -b feat/launcher-core
```

---

### Task 5: Arg parser — `ConvertFrom-SbxArgs`

**Files:**
- Create: `sbx.ps1`
- Create: `tests/Parser.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces: `ConvertFrom-SbxArgs([string[]]$Arguments)` → `[pscustomobject]` with fields:
  `Command` (`'run'|'ls'|'stop'`), `Path` (string|`$null`), `Scratch` (bool),
  `Ssh` (bool), `Window` (`'window'|'tab'|'here'`), `Name` (string|`$null`),
  `Target` (string|`$null`). Consumed by `Invoke-Sbx` (Task 8) and `Build-SbxRunArgs` (Task 7).

- [ ] **Step 1: Write the failing test**

`tests/Parser.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-SbxArgs' {
    It 'treats no args as a scratch run in a new window' {
        $o = ConvertFrom-SbxArgs @()
        $o.Command | Should -Be 'run'
        $o.Scratch | Should -BeTrue
        $o.Path    | Should -BeNullOrEmpty
        $o.Window  | Should -Be 'window'
        $o.Ssh     | Should -BeFalse
    }
    It 'treats a bare path as a real run' {
        $o = ConvertFrom-SbxArgs @('C:\repo')
        $o.Scratch | Should -BeFalse
        $o.Path    | Should -Be 'C:\repo'
    }
    It 'parses --here, --tab, --ssh, --name' {
        (ConvertFrom-SbxArgs @('--here','C:\r')).Window | Should -Be 'here'
        (ConvertFrom-SbxArgs @('--tab','C:\r')).Window  | Should -Be 'tab'
        (ConvertFrom-SbxArgs @('--ssh','C:\r')).Ssh     | Should -BeTrue
        (ConvertFrom-SbxArgs @('--name','foo','C:\r')).Name | Should -Be 'foo'
    }
    It 'parses the ls subcommand' {
        (ConvertFrom-SbxArgs @('ls')).Command | Should -Be 'ls'
    }
    It 'parses stop <name>' {
        $o = ConvertFrom-SbxArgs @('stop','sbx-repo-abc123')
        $o.Command | Should -Be 'stop'
        $o.Target  | Should -Be 'sbx-repo-abc123'
    }
    It 'throws on an unknown --flag' {
        { ConvertFrom-SbxArgs @('--bogus') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Parser.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `ConvertFrom-SbxArgs` not recognized (`sbx.ps1` empty/absent).

- [ ] **Step 3: Implement `ConvertFrom-SbxArgs` in `sbx.ps1`**

`sbx.ps1` (create with just this function for now):
```powershell
function ConvertFrom-SbxArgs {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    $opts = [ordered]@{
        Command = 'run'; Path = $null; Scratch = $true
        Ssh = $false; Window = 'window'; Name = $null; Target = $null
    }

    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'ls') {
        $opts.Command = 'ls'; return [pscustomobject]$opts
    }
    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq 'stop') {
        $opts.Command = 'stop'; $opts.Target = $Arguments[1]
        return [pscustomobject]$opts
    }

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        switch ($Arguments[$i]) {
            '--here' { $opts.Window = 'here' }
            '--tab'  { $opts.Window = 'tab' }
            '--ssh'  { $opts.Ssh = $true }
            '--name' { $i++; $opts.Name = $Arguments[$i] }
            default  {
                if ($Arguments[$i] -like '--*') { throw "Unknown option: $($Arguments[$i])" }
                $opts.Path = $Arguments[$i]; $opts.Scratch = $false
            }
        }
    }
    return [pscustomobject]$opts
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Parser.Tests.ps1 -Output Detailed"
```
Expected: all `ConvertFrom-SbxArgs` tests PASS.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Parser.Tests.ps1
git commit -m "feat: sbx arg parser (ConvertFrom-SbxArgs) + tests"
```

---

### Task 6: Host→mount path translation — `ConvertTo-SbxMountPath`

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/MountPath.Tests.ps1`

**Interfaces:**
- Consumes: the winning `-v` source form recorded in `docs/FINDINGS.md` (Task 2).
- Produces: `ConvertTo-SbxMountPath([string]$HostPath)` → the `-v` **source** string for that host path. Consumed by `Build-SbxRunArgs` (Task 7).

> **Confirmed by Task 2 (`docs/FINDINGS.md`).** The winning `-v` source form is the **host Windows drive-letter path**, emitted **forward-slash normalized** (`C:/Users/user/src/foo`). The `/mnt/c` WSL-view form was tested and **fails silently** (mounts an empty location) — never emit it. The code and tests below encode the confirmed form.

- [ ] **Step 1: Write the failing test**

`tests/MountPath.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertTo-SbxMountPath' {
    It 'translates a Windows path to the forward-slash Windows form (per docs/FINDINGS.md)' {
        ConvertTo-SbxMountPath 'C:\Users\user\src\foo' | Should -Be 'C:/Users/user/src/foo'
    }
    It 'normalizes an already-forward-slash path and strips a trailing slash' {
        ConvertTo-SbxMountPath 'C:/Users/user/src/foo/' | Should -Be 'C:/Users/user/src/foo'
    }
    It 'throws on a non-drive (UNC) path' {
        { ConvertTo-SbxMountPath '\\server\share\x' } | Should -Throw
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/MountPath.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `ConvertTo-SbxMountPath` not defined.

- [ ] **Step 3: Implement `ConvertTo-SbxMountPath` in `sbx.ps1`**

Append to `sbx.ps1`:
```powershell
function ConvertTo-SbxMountPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostPath)

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/MountPath.Tests.ps1 -Output Detailed"
```
Expected: all PASS. (If Task 2's finding differed and you reconciled Step 1/Step 3, they still PASS on the recorded form.)

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/MountPath.Tests.ps1
git commit -m "feat: host->mount path translation + tests"
```

---

### Task 7: Naming + `wslc run` command composer

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/RunArgs.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-SbxArgs` output shape (Task 5), `ConvertTo-SbxMountPath` (Task 6).
- Produces:
  - `Get-SbxContainerName([string]$Path, [string]$Override, [string]$Suffix)` → container name string.
  - `Build-SbxRunArgs([psobject]$Options, [string]$Name, [string]$Image='sbx:latest', [string]$AuthVolume='sbx-claude-auth')` → `[string[]]` args to pass to `wslc` (starting with `run`). Consumed by `Invoke-Sbx` (Task 8).

- [ ] **Step 1: Write the failing tests**

`tests/RunArgs.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxContainerName' {
    It 'uses the override verbatim when given' {
        Get-SbxContainerName -Path 'C:\x\repo' -Override 'myname' | Should -Be 'myname'
    }
    It 'builds sbx-<basename>-<suffix> for a real path' {
        Get-SbxContainerName -Path 'C:\x\my-repo' -Suffix 'abc123' | Should -Be 'sbx-my-repo-abc123'
    }
    It 'uses "scratch" as the basename when no path' {
        Get-SbxContainerName -Path $null -Suffix 'abc123' | Should -Be 'sbx-scratch-abc123'
    }
}

Describe 'Build-SbxRunArgs' {
    It 'scratch run: --rm, auth volume, no /work mount, no ssh' {
        $o = ConvertFrom-SbxArgs @()
        $a = Build-SbxRunArgs -Options $o -Name 'sbx-scratch-abc123'
        ($a -join ' ') | Should -BeLike 'run *--rm*'
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        ($a -join ' ') | Should -Not -BeLike '*:/work*'
        ($a -join ' ') | Should -Not -BeLike '*/.ssh*'
        $a[-2..-1]     | Should -Be @('claude','--dangerously-skip-permissions')
    }
    It 'real run: mounts <path> at /work with -w /work and names it' {
        $o = ConvertFrom-SbxArgs @('C:\Users\user\src\foo')
        $a = Build-SbxRunArgs -Options $o -Name 'sbx-foo-abc123'
        ($a -join ' ') | Should -BeLike '*-v C:/Users/user/src/foo:/work*'
        ($a -join ' ') | Should -BeLike '*-w /work*'
        ($a -join ' ') | Should -BeLike '*--name sbx-foo-abc123*'
        ($a -join ' ') | Should -BeLike '*--label sbx=1*'
    }
    It 'ssh run: adds ~/.ssh read-only' {
        $o = ConvertFrom-SbxArgs @('--ssh','C:\Users\user\src\foo')
        $a = Build-SbxRunArgs -Options $o -Name 'sbx-foo-abc123'
        $sshExpected = (ConvertTo-SbxMountPath (Join-Path $HOME '.ssh')) + ':/home/agent/.ssh:ro'
        ($a -join ' ') | Should -BeLike "*-v $sshExpected*"
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/RunArgs.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Get-SbxContainerName` / `Build-SbxRunArgs` not defined.

- [ ] **Step 3: Implement both functions in `sbx.ps1`**

Append to `sbx.ps1`:
```powershell
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

function Build-SbxRunArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Options,
        [Parameter(Mandatory)][string]$Name,
        [string]$Image = 'sbx:latest',
        [string]$AuthVolume = 'sbx-claude-auth'
    )
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add('run'); $a.Add('--rm'); $a.Add('-i'); $a.Add('-t')
    $a.Add('--name');  $a.Add($Name)
    $a.Add('--label'); $a.Add('sbx=1')
    $a.Add('-v');      $a.Add("${AuthVolume}:/home/agent/.claude")   # always
    if (-not $Options.Scratch) {
        $src = ConvertTo-SbxMountPath -HostPath $Options.Path
        $a.Add('-v'); $a.Add("${src}:/work")
        $a.Add('-w'); $a.Add('/work')
    }
    if ($Options.Ssh) {
        $sshSrc = ConvertTo-SbxMountPath -HostPath (Join-Path $HOME '.ssh')
        $a.Add('-v'); $a.Add("${sshSrc}:/home/agent/.ssh:ro")
    }
    $a.Add($Image)
    $a.Add('claude'); $a.Add('--dangerously-skip-permissions')
    return ,$a.ToArray()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/RunArgs.Tests.ps1 -Output Detailed"
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/RunArgs.Tests.ps1
git commit -m "feat: container naming + wslc run command composer + tests"
```

---

### Task 8: Dispatch + window spawning — `Invoke-Sbx`, `Start-WtSbx`

**Files:**
- Modify: `sbx.ps1`
- Create: `tests/Dispatch.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertFrom-SbxArgs` (T5), `Get-SbxContainerName` + `Build-SbxRunArgs` (T7), plus `Get-SbxList`/`Stop-Sbx` (defined in T9 — referenced by name here; the run/here/tab paths are what this task tests).
- Produces: `Invoke-Sbx([string[]]$Arguments)` — the entry point. `--here` runs `wslc @runArgs` in-process; default/`--tab` spawn via `Start-WtSbx`.

- [ ] **Step 1: Write the failing tests (mock the side effects)**

`tests/Dispatch.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Invoke-Sbx dispatch' {
    It '--here invokes wslc in-process with composed run args' {
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @('--here','C:\Users\user\src\foo')
        ($script:seen -join ' ') | Should -BeLike 'run *--dangerously-skip-permissions'
        ($script:seen -join ' ') | Should -BeLike '*-v C:/Users/user/src/foo:/work*'
        Should -Invoke wslc -Times 1
    }
    It 'default run spawns a new WT window (no in-process wslc)' {
        Mock -CommandName Start-Process -MockWith { $script:sp = $args }
        Mock -CommandName wslc -MockWith { throw 'should not run in-process' }
        Invoke-Sbx @('C:\Users\user\src\foo')
        Should -Invoke Start-Process -Times 1
        ($script:sp -join ' ') | Should -BeLike '*wt.exe*'
    }
    It 'scratch --here runs with --rm and no /work' {
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @('--here')
        ($script:seen -join ' ') | Should -BeLike 'run *--rm*'
        ($script:seen -join ' ') | Should -Not -BeLike '*:/work*'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Dispatch.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `Invoke-Sbx` not defined.

- [ ] **Step 3: Implement `Invoke-Sbx` and `Start-WtSbx` in `sbx.ps1`**

Append to `sbx.ps1`:
```powershell
function Start-WtSbx {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$RunArgs, [switch]$NewTab)
    # Quote any run-arg that contains whitespace, then run inside a fresh pwsh window.
    $quoted = $RunArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $inner  = 'wslc ' + ($quoted -join ' ')
    $wt = [System.Collections.Generic.List[string]]::new()
    if ($NewTab) { $wt.Add('-w'); $wt.Add('0'); $wt.Add('new-tab') }
    $wt.Add('pwsh'); $wt.Add('-NoExit'); $wt.Add('-Command'); $wt.Add($inner)
    Start-Process wt.exe -ArgumentList $wt.ToArray()
}

function Invoke-Sbx {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())
    $o = ConvertFrom-SbxArgs -Arguments $Arguments
    switch ($o.Command) {
        'ls'   { return Get-SbxList }
        'stop' { return Stop-Sbx -Name $o.Target }
    }
    $name    = Get-SbxContainerName -Path $o.Path -Override $o.Name
    $runArgs = Build-SbxRunArgs -Options $o -Name $name
    switch ($o.Window) {
        'here'  { & wslc @runArgs }
        'tab'   { Start-WtSbx -RunArgs $runArgs -NewTab }
        default { Start-WtSbx -RunArgs $runArgs }
    }
}

Set-Alias -Name sbx -Value Invoke-Sbx
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests/Dispatch.Tests.ps1 -Output Detailed"
```
Expected: all PASS. (`Get-SbxList`/`Stop-Sbx` are referenced only on the `ls`/`stop` branches, which these tests don't hit; they land in Task 9.)

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Dispatch.Tests.ps1
git commit -m "feat: sbx dispatch + WT window/tab spawning + tests"
```

---

### Task 9: Subcommands — `Get-SbxList`, `Stop-Sbx`

**Files:**
- Modify: `sbx.ps1`
- Modify: `docs/FINDINGS.md` (record actual `wslc list --format json` field names)
- Create: `tests/Subcommands.Tests.ps1`

**Interfaces:**
- Consumes: live `wslc list`/`stop`/`remove`.
- Produces: `Get-SbxList()` → objects for containers whose name starts `sbx-`; `Stop-Sbx([string]$Name)` → stops then removes one.

- [ ] **Step 1: Inspect the real `wslc list --format json` shape (fill field names)**

Run:
```powershell
wslc run -d --name sbx-probe-json --label sbx=1 sbx:latest sleep 60 | Out-Null
wslc list --all --format json
wslc stop sbx-probe-json; wslc remove sbx-probe-json 2>$null
```
Record the JSON property names (e.g. `Names`/`name`, `Image`, `State`/`Status`) in `docs/FINDINGS.md`. If they differ from `name`/`image`/`status` used below, adjust Step 3's `Where-Object`/`Select-Object` and Step 2's mock to match.

- [ ] **Step 2: Write the failing tests (mock `wslc`)**

`tests/Subcommands.Tests.ps1`:
```powershell
BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxList' {
    It 'returns only sbx-* containers from wslc list json' {
        Mock -CommandName wslc -MockWith {
            '[{"name":"sbx-foo-abc123","image":"sbx:latest","status":"running"},
              {"name":"unrelated","image":"debian","status":"running"}]'
        }
        $r = Get-SbxList
        @($r).Count | Should -Be 1
        $r[0].name  | Should -Be 'sbx-foo-abc123'
    }
}

Describe 'Stop-Sbx' {
    It 'stops then removes the named container' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Stop-Sbx -Name 'sbx-foo-abc123'
        $script:calls | Should -Contain 'stop sbx-foo-abc123'
        ($script:calls -join '|') | Should -BeLike '*remove sbx-foo-abc123*'
    }
}
```

- [ ] **Step 3: Implement `Get-SbxList` and `Stop-Sbx` in `sbx.ps1`**

Append to `sbx.ps1` (adjust field names per Step 1 if needed):
```powershell
function Get-SbxList {
    [CmdletBinding()] param()
    $json = & wslc list --all --format json 2>$null
    if (-not $json) { return }
    @($json | ConvertFrom-Json) |
        Where-Object { $_.name -like 'sbx-*' } |
        Select-Object name, image, status
}

function Stop-Sbx {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    & wslc stop $Name
    & wslc remove $Name 2>$null   # --rm usually removes on stop; idempotent safety net
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```powershell
pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"
```
Expected: the whole suite (Parser, MountPath, RunArgs, Dispatch, Subcommands, Smoke) PASSES.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/Subcommands.Tests.ps1 docs/FINDINGS.md
git commit -m "feat: sbx ls + stop subcommands + tests"
git checkout main && git merge --no-ff feat/launcher-core -m "merge: launcher core" && git checkout -b feat/install-verify
```

---

### Task 10: `$PROFILE` integration + install docs

**Files:**
- Create: `install.ps1`
- Modify: `README.md`

**Interfaces:**
- Consumes: `sbx.ps1` (dot-sourced).
- Produces: `sbx` available as a command in every new `pwsh` session.

- [ ] **Step 1: Write `install.ps1` (idempotent profile wiring)**

`install.ps1`:
```powershell
#requires -Version 7
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$line = ". '$repo\sbx.ps1'"
$profilePath = $PROFILE.CurrentUserAllHosts
$dir = Split-Path -Parent $profilePath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force $profilePath | Out-Null }
$existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ($existing -notmatch [regex]::Escape($line)) {
    Add-Content $profilePath "`n# sbx launcher`n$line"
    Write-Host "Added sbx to $profilePath"
} else {
    Write-Host "sbx already present in $profilePath"
}
Write-Host "Open a new pwsh session, then: sbx --here <path>"
```

- [ ] **Step 2: Run the installer**

Run:
```powershell
pwsh -NoProfile -File install.ps1
```
Expected: prints "Added sbx to …" (or "already present" on re-run — verify idempotency by running twice; the second time must say "already present").

- [ ] **Step 3: Verify `sbx` resolves in a fresh profile-loading session**

Run:
```powershell
pwsh -Command "Get-Command sbx | Select-Object -ExpandProperty Name"
```
Expected: `Invoke-Sbx` (the alias target) — proving the profile dot-sourced `sbx.ps1`.

- [ ] **Step 4: Update README install section**

Add to `README.md`:
```markdown
## Install

    wslc build -t sbx:latest -f Sandboxfile .   # build the image (once)
    wslc volume create sbx-claude-auth          # create auth volume (once)
    # log in once — see docs/LOGIN.md
    pwsh -File install.ps1                       # wire sbx into your $PROFILE
    # open a new pwsh session; `sbx --here <path>` to smoke-test
```

- [ ] **Step 5: Commit**

```bash
git add install.ps1 README.md
git commit -m "feat: installer wires sbx into \$PROFILE + install docs"
```

---

### Task 11: Manual integration checklist (live verification)

**Files:**
- Create: `verify/CHECKLIST.md`

**Interfaces:**
- Consumes: the fully built system (image, auth volume, installed launcher).
- Produces: a filled-out checklist proving the spec's verification strategy on real containers.

- [ ] **Step 1: Write `verify/CHECKLIST.md`**

`verify/CHECKLIST.md`:
```markdown
# sbx integration checklist (run on the target machine)

Prereqs: image `sbx:latest` built, `sbx-claude-auth` volume logged in, `sbx` installed.
Use `--here` to keep output in the current terminal.

## 1. Isolation — no host C:, no other repos, mounted repo writable
- [ ] `sbx --here <a-real-repo>` → inside: `ls /` shows NO `mnt/c` wandering into place
      beyond the mount, and `/work` lists that repo's files.
- [ ] Inside: `test -e /work/<known-file> && echo OK` → `OK`.
- [ ] Inside: pick a DIFFERENT known host repo path; confirm it does NOT exist in the
      container filesystem.
- [ ] Inside: `touch /work/_sbx_write_test && rm /work/_sbx_write_test` → succeeds
      (mounted repo is writable by `agent`).

## 2. Scratch leaves nothing
- [ ] `sbx --here` (no path) → exit → `wslc list --all` shows no leftover scratch container.

## 3. Concurrency — two repos side by side
- [ ] `sbx <repoA>` and `sbx <repoB>` (two windows) run simultaneously.
- [ ] `sbx ls` lists BOTH, distinct names, each `sbx-<basename>-<rand>`.
- [ ] Each container sees only its own repo at `/work`.

## 4. Auth persistence
- [ ] A fresh `sbx --here <repo>` is already logged in (no re-auth prompt),
      served by the `sbx-claude-auth` volume.

## 5. SSH gating
- [ ] `sbx --here <nas-repo>` (NO --ssh): inside, `ls /home/agent/.ssh` → absent/empty;
      a git op against the NAS remote fails on missing key.
- [ ] `sbx --ssh --here <nas-repo>`: inside, `/home/agent/.ssh` present read-only;
      the NAS git remote is reachable; `touch /home/agent/.ssh/x` fails (read-only).

## 6. Cleanup
- [ ] `sbx stop <name>` removes a live one; `sbx ls` no longer lists it.
```

- [ ] **Step 2: Execute the checklist and tick each box**

Work through `verify/CHECKLIST.md` on the machine. For any box that fails, capture the symptom in `docs/FINDINGS.md` and fix the relevant task's code before ticking. (Common expected fixes: mount-source form → Task 6; volume ownership → Task 4 Step 3; `wslc list` field names → Task 9.)

- [ ] **Step 3: Commit and integrate**

```bash
git add verify/CHECKLIST.md docs/FINDINGS.md
git commit -m "test: live integration checklist (isolation/scratch/concurrency/auth/ssh)"
git checkout main && git merge --no-ff feat/install-verify -m "merge: install + verification"
```

---

## Self-Review

**Spec coverage:**
- Goal (skip-permissions in minimal-blast-radius wslc container, no Docker, multi-window) → Tasks 3, 7, 8, 11.
- Blast radius / isolation (no host FS, other repos absent) → Task 11 §1; enforced by single-mount composition in Task 7.
- Three components: image → Task 3; launcher → Tasks 5–10; auth volume → Task 4.
- Full command surface (`sbx <path>`, bare scratch, `--here`, `--tab`, `--ssh`, `--name`, `ls`, `stop`) → Tasks 5 (parse), 7 (compose), 8 (dispatch/window), 9 (ls/stop); defaults (new window, no ssh, auth always) → Task 7 + Task 8.
- Container naming `sbx-<repo>-<rand>` → Task 7.
- SSH v1 read-only `~/.ssh` gated by `--ssh` → Task 7 + Task 11 §5. (v2 ssh-agent = out of scope, noted.)
- Orchestration (window per repo; tmux within) → tmux in image (Task 3), window-per-call (Task 8), concurrency check (Task 11 §3).
- Known risk / empirical mount probe → Task 2 (gate) feeding Task 6.
- Testing/verification strategy → Pester Tasks 5–9 + `verify/CHECKLIST.md` Task 11.
- Out-of-scope items → recorded in Global Constraints; no tasks (correct).

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". The only deliberately deferred literals are (a) the mount-source form in Task 6 and (b) `wslc list` JSON field names in Task 9 — both are *empirically determined* values with an explicit probe step (Task 2, Task 9 Step 1) and a named reconciliation instruction, not lazy placeholders.

**Type consistency:** `ConvertFrom-SbxArgs` produces `{Command,Path,Scratch,Ssh,Window,Name,Target}` — consumed with those exact names in Tasks 7 (`$Options.Scratch/.Path/.Ssh`) and 8 (`$o.Command/.Path/.Name/.Window/.Target`). `Build-SbxRunArgs(-Options,-Name,-Image,-AuthVolume)` and `Get-SbxContainerName(-Path,-Override,-Suffix)` signatures match their call sites in Task 8. `ConvertTo-SbxMountPath` single-arg contract consistent across Tasks 6–7. `sbx` alias → `Invoke-Sbx` consistent in Tasks 8 and 10.
