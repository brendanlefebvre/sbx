# sbx — project memory

Launcher for running Claude Code with `--dangerously-skip-permissions` inside a
throwaway sandbox container — `wslc` (WSL Containers) on Windows, `docker` on
macOS. See `docs/superpowers/specs/` for the design and `docs/superpowers/plans/`
for the implementation plan.

## Build / run
- Windows: build the image with `wslc build -t sbx:latest -f Sandboxfile .`; create the
  auth volume once with `wslc volume create sbx-claude-auth`.
- macOS: build the image with `docker build -t sbx:latest -f Sandboxfile .`; create the
  auth volume once with `docker volume create sbx-claude-auth`. The verified macOS
  runtime is **OrbStack** (its `docker` CLI); see `docs/FINDINGS.md` for what that
  scopes — notably the volume-ownership result that lets us ship an unmodified image.
- The container runtime is `wslc` on Windows / `docker` on macOS, overridable via
  `SBX_RUNTIME` (e.g. podman/colima/orbstack). On macOS the override is always honored;
  on Windows only `--here` honors it — the default window/tab mode hardcodes `wslc`.
- Launcher lives in `sbx.ps1`; `$PROFILE` dot-sources it (see README / Task 10).

## Test
- Unit (pure builder fns):  `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
- Integration (live container):  run `verify/CHECKLIST.md` by hand on this machine.

## Conventions
- Git: feature branches `feat/<slug>`, granular commits, merge to `main` with `--no-ff`; push `main` to the `origin` sync remote. No PRs.
- All launcher logic is PowerShell 7 (`pwsh`): native Windows paths on Windows (not MSYS
  bash), absolute POSIX paths on macOS.
- `wslc` is public preview, currently **2.9.4.0** (auto-updated from 2.9.3.0 mid-project);
  treat CLI surprises as preview quirks and record them in `docs/FINDINGS.md`, which
  covers findings from both versions and flags which is which.
- macOS is foreground-only (no new-window/tab spawn): `--tab` is rejected and `--here` is
  the default and only mode. (`--window` is not a flag on any platform — `window` is just
  the internal default; passing it errors as an unknown option everywhere.)
- **Unified workspace (v2):** one long-lived container `sbx-main` holds every added
  project, not one container per repo. `sbx add <path>` moves the repo into the workspace
  dir (default `~/sbx-ws`, override `SBX_WORKSPACE`) and leaves a junction (Windows) /
  symlink (macOS) at the original path so host tooling keeps working; `sbx rm <name>`
  reverses it. The move-back target is recorded in a host-side manifest,
  `~/.sbx/origins.json` (outside the workspace, so the container can't tamper with where
  `rm` moves things). Claude session history and memory are NOT per-repo volumes anymore —
  they live in the single shared `sbx-claude-auth` volume, keyed naturally by cwd
  (`/work/<name>`) under Claude's own `~/.claude/projects` layout. Orphaned `sbx-proj-*`
  volumes from the v1 per-repo model are retired; reap them by hand
  (`wslc volume remove <name>`) and don't recreate the pattern.

Now say: "I've reviewed the project memory."
