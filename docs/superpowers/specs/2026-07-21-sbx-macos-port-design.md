# sbx — macOS port design

**Date:** 2026-07-21
**Status:** Design approved; implementation plan not yet written.
**Builds on:** `2026-07-21-sbx-wsl-container-sandbox-design.md` (the original Windows design).

## Goal

Extend `sbx` so the same thing it does on Windows — run
`claude --dangerously-skip-permissions` inside a throwaway container whose only
writable host surface is the one mounted repo — works on macOS (Apple Silicon),
driven from a terminal reached over SSH.

The threat model is unchanged and OS-independent: contain the blast radius of
`--dangerously-skip-permissions` to the single mounted repo (git-recoverable),
plus the persistent `.claude` auth volume and, on `--ssh` runs, a read-only
`~/.ssh`. Network egress and general credential theft remain out of scope, per
the original spec.

## Environment & topology (decided)

- **Host:** this Mac (macOS 26, arm64). `docker` CLI is present and is the
  runtime. `pwsh` is **not** installed and will be added via
  `brew install powershell`.
- **How the user reaches it:** SSH'd *into* the Mac (e.g. from an iPad via
  Termius). sbx and docker run on the Mac; the user only ever sees a **text
  terminal** — there is no Mac GUI session to open a window into.
- **Consequence:** the entire Windows Terminal (`wt.exe`) new-window / new-tab
  mechanism has **no meaning** on macOS. On the Mac, sbx always runs
  **foreground** in the current terminal.

## Decisions

1. **Single cross-platform codebase, OS branches at the seams** (not a separate
   Mac launcher, not per-OS modules). The pure builder functions
   (`ConvertFrom-SbxArgs`, `Build-SbxRunArgs`, `Get-SbxContainerName`,
   `Get-SbxProjectVolumeName`) stay shared and OS-agnostic. `$IsMacOS` /
   `$IsWindows` branches appear only where behavior genuinely diverges: runtime
   binary, mount-path form, terminal spawn (Windows-only), `ls`/`stop`
   formatting, and install wiring. Windows keeps working; Pester tests stay
   green and gain Mac cases.

2. **Keep PowerShell.** `brew install powershell`. This preserves the repo's
   pure/impure split and the existing Pester test suite, and keeps ~70% of the
   code shared.

3. **Foreground-only on macOS.** No window/tab spawning. Concurrency is the
   user's own responsibility: multiple Termius sessions or their own host tmux,
   each running its own `sbx`.

4. **Same-repo parallelism is dropped on macOS (YAGNI).** Different repos go in
   different host tmux panes / Termius sessions, each running `sbx`. The
   in-image tmux stops being part of the Mac design (tmux stays *installed* in
   the shared image because Windows still relies on it; it is simply not
   featured on the Mac side). No `sbx exec`, no nested tmux.

5. **`--ssh` is in scope for v1** on macOS (the user does NAS git operations —
   this repo's `origin` is `user@nas` — from inside sandboxes on
   the Mac too).

6. **Unified image with a privilege-dropping entrypoint** (not a Mac-specific
   image tag). See §Image below.

## Architecture — the five seams

### §1 Runtime & mount-path abstraction

- Resolve the runtime once at load: `wslc` on Windows, `docker` on macOS. An
  optional `SBX_RUNTIME` env override lets OrbStack/colima/podman users (all of
  which honor the `docker` CLI) point elsewhere. Every `& wslc` call becomes
  `& $runtime`.
- The runtime verbs are compatible across both — `run`, `-v`, `volume`, `stop`,
  `rm`, `build` — with **one** exception: the list command (§4).
- `ConvertTo-SbxMountPath` branches:
  - **Windows:** keep the existing drive-letter → forward-slash logic.
  - **macOS:** resolve to an absolute POSIX path and hand it to docker verbatim
    (`/Users/user/src/foo:/work` mounts directly). The dangerous `/mnt/c`
    silent-empty-mount failure mode has no macOS analog, so the Mac branch is
    just an absolute-path guard.

### §2 Unified image & the volume-ownership gotcha

The one thing that will **not** work on a plain rebuild. `docs/FINDINGS.md`
records that wslc named volumes mount owned by `agent`, but **Docker named
volumes mount `root:root`**. So on macOS the auth volume at `/home/agent/.claude`
and the per-repo `projects` volume come up root-owned and the non-root `agent`
cannot write its own login — Claude fails to persist auth.

Fix — the standard privilege-drop entrypoint:

- Drop `USER agent` from the image. The entrypoint starts as **root**,
  `chown -R agent:agent` the volume mount points (`~/.claude`,
  `~/.claude/projects`), performs the existing `.ssh` copy-to-`0600`, then drops
  to `agent` via **`gosu`** (installed via apt) and `exec`s the command.
- On wslc, where those volumes already come up agent-owned, the chown is a
  **harmless, idempotent no-op** — so it remains **one unified image**, no
  Mac-specific tag.

Tradeoff (accepted): the container now starts as root and drops privileges on
*both* OSes. This is more correct, not less, but it touches the shared runtime
path, so `verify/CHECKLIST.md` must be re-run on Windows to confirm no
regression. (Rejected alternative: gate the chown behind a `SBX_FIX_PERMS` env
the Mac launcher sets — the unified root-drop is cleaner and worth the
re-verify.)

The `git config` image settings are unchanged and remain correct on macOS:
`safe.directory '*'` is still needed (bind-mount ownership), and
`core.autocrlf input` is a harmless no-op on a LF-native host.

### §3 Command surface & install on macOS

- The arg parser stays shared. On macOS the effective run mode is always
  foreground: `--here` is a no-op (already the default behavior) and `--tab`
  errors with "not supported on macOS." Everything else carries over unchanged:
  `sbx <path>`, `sbx` (scratch), `--ssh`, `--name`, `sbx ls`,
  `sbx stop <name|--all>`.
- Install gains an `$IsMacOS` branch in `install.ps1`. Instead of `$PROFILE`
  dot-sourcing + Windows user PATH, it drops a POSIX shim named `sbx`
  (`exec pwsh -NoProfile -File <repo>/sbx-cli.ps1 "$@"`) into `~/.local/bin`
  (created if missing; warns if that dir is not on `PATH`). This mirrors the
  `sbx.cmd` shim on Windows and works from any shell reaching the Mac over SSH.
  No zshrc function is needed (foreground-only ⇒ the ~300ms pwsh startup before
  a long Claude session is negligible). `sbx-cli.ps1` already exists and is
  OS-agnostic; the shim just execs pwsh against it.

### §4 `ls` / `stop` & the list-format divergence

- `Get-SbxList` branches by runtime:
  - **Windows:** existing `wslc list --all --format json` (PascalCase fields,
    int `State` enum).
  - **macOS:** `docker ps -a --filter label=sbx=1 --format '{{json .}}'`, mapping
    Docker's `Names` / `Image` / `Status` (a string like `Up 3 minutes` /
    `Exited (0)`) into the same `Name` / `Image` / `Status` output shape.
  - Filtering on the `sbx=1` label (already set in `Build-SbxRunArgs`) is more
    robust than the name-prefix filter and is used on the Mac branch.
- `Stop-Sbx` becomes `docker stop` / `docker rm` (idempotent), with the same
  `--all` reaper driven off `Get-SbxList`.

### §5 Terminal spawn (Windows-only)

`Start-WtSbx` and the `wt.exe` / `-EncodedCommand` machinery remain the Windows
path. On macOS `Invoke-Sbx` never calls them — it always runs the foreground
`try { & $runtime @runArgs } finally { stop; rm }` path. With `--rm` and a
foreground run, container cleanup is automatic on Claude exit; the `finally` is
belt-and-suspenders for Ctrl-C.

## Verification strategy

Mirror the Windows discipline.

1. **Empirical probe pass FIRST** (before building on any assumption), recorded
   in `docs/FINDINGS.md` under a macOS section — the same way the Windows path
   syntax was proven before the launcher was built around it:
   - **P1** — `docker run --rm -v /Users/.../repo:/work <img> ls -la /work`:
     host files visible **and** `/work` writable by `agent`?
   - **P2** — named volume `sbx-claude-auth:/home/agent/.claude` ownership on
     mount (expected `root:root`, confirming the need for the chown/gosu fix).
   - **P3** — nested `projects` volume ownership after the entrypoint fix
     (expected `agent:agent`).
   - **P4** — `--ssh` mount ownership + the `0600` copy works; `git ls-remote`
     reaches the NAS remote over SSH.
   - **P5** — `docker ps -a --format '{{json .}}'` field shape, to pin
     `Get-SbxList`'s Mac mapping.
2. **Pester unit cases** for the Mac branches (mount-path passthrough, runtime
   selection, Docker list parsing), runnable under pwsh on macOS.
3. **macOS section appended to `verify/CHECKLIST.md`** — live-container isolation
   / scratch-cleanup / auth-persistence / `--ssh` gating checks.
4. **Windows non-regression:** re-run `verify/CHECKLIST.md` on Windows after the
   image change (root-drop entrypoint).

## Docs to update

- **README** — a macOS install/usage block (`brew install powershell`,
  `docker build`, volume create, `pwsh -File install.ps1`, shim on `PATH`).
- **CLAUDE.md** — conventions widened to name docker/macOS alongside
  wslc/Windows (build/run commands, "PowerShell 7 native paths" caveat).
- **docs/FINDINGS.md** — the macOS probe results (§Verification P1–P5).

## Out of scope for the macOS port (YAGNI)

- Window/tab spawning of any kind (no GUI over SSH).
- Same-repo parallelism / `sbx exec` / in-image tmux on the Mac.
- ssh-agent forwarding (still the shared v2 improvement from the original spec).
- Apple's native `container` runtime (macOS 26) — docker is the pragmatic pick
  and isn't installed; `SBX_RUNTIME` leaves the door open later.
