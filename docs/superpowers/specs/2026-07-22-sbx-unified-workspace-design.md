# sbx v2 — unified workspace sandbox

**Date:** 2026-07-22
**Status:** Design approved; supersedes the per-repo container model of
`2026-07-21-sbx-wsl-container-sandbox-design.md` (scratch mode and the image
survive unchanged).

## Goal

Replace the one-container-per-repo model with **one unified sandbox
environment** to which projects are added and removed at will — the substrate
for cross-project orchestration (one agent spanning repos now, a coordinated
fleet later; the Yegge ladder of agentic usage modes). Add/remove must be
**live**: no container restart, no interruption of running sessions.

## Blast radius (revised from v1)

The v1 goal was "a rogue command can wipe at most the one mounted repo." The
unified model deliberately widens this to **the added set**: every project
currently in the workspace is simultaneously writable by every session. Each is
git-recoverable; adding a repo is an explicit act of exposure. Unchanged from
v1: no path from the container to the host OS or to any repo *not* added; no
SSH keys in the container (see Sync). Scratch mode remains the
maximally-contained option.

Two costs accepted explicitly, in exchange for orchestration:

1. All added repos are exposed at once (vs. exactly one).
2. The container persists across sessions (vs. dying with each run) — see
   "Pet management" for the mitigation.

## Empirical foundation (see FINDINGS.md, 2026-07-22 section)

- Junctions/symlinks inside a bind-mounted dir are **broken inside** wslc
  containers (dangling zero-length symlinks) — and equivalently broken on
  macOS/Linux bind mounts (client-side resolution). "Symlink projects into the
  workspace" is not viable on any platform.
- **Real directories** created under the mount after container start appear
  **live**, read-write, both directions.
- Junctions **are** resolved for host-side accessors. The design's core trick:
  the real dir moves into the workspace; a junction left at the original path
  keeps host tooling working.

## Core model

**One workspace, one container, N projects.**

- A single host **workspace dir** — default `~/sbx-ws` (`C:\Users\user\sbx-ws`
  / `/Users/user/sbx-ws`) — is the only repo-bearing mount, mounted at `/work`
  in a single long-lived container **`sbx-main`** built from `sbx:latest`.
  Exactly two mounts at create time: the workspace and `sbx-claude-auth`.
- `sbx-main`'s anchor process is a **tmux server**. Each project gets a tmux
  **session named after its directory** (windows within it are the user's to
  multiply); a **`hub` session** at `/work` is the orchestrator's cross-project
  vantage point. Every `sbx` invocation opens a terminal window/tab that
  `exec`s into the appropriate tmux session, creating it on first use. (Note:
  two terminals attached to one tmux session mirror each other — the intended
  flow is one terminal per session, many tmux windows within.)
- **`sbx add <path>`** moves the repo into the workspace (same-volume rename;
  a cross-volume source is refused with an explanatory error) and leaves a junction (Windows) /
  symlink (macOS) at the original path. **`sbx rm <name>`** kills the
  project's tmux session, moves the repo back, removes the link. Both live.
- **Pet management:** the container is disposable *by policy*. All durable
  state lives in the workspace and volumes; environment needs belong in the
  `Sandboxfile`, not accreted in the container. **`sbx rebuild`** destroys and
  recreates `sbx-main` (image upgrades, wedged state, wslc quirk resets); cost
  is running tmux sessions only.
- **Future, additive:** `sbx add --clone <path|url>` drops a *clone* into the
  workspace instead of moving — same container model, enables same-repo
  parallel agents (per-agent checkouts coordinated via git) and native-fs
  performance, at the cost of git-ceremony sync. Not v1.

## Command surface

| Invocation      | Behavior                                                                                       |
| --------------- | ---------------------------------------------------------------------------------------------- |
| `sbx add <path>` | Move repo into workspace; leave junction/symlink at original path. Live.                       |
| `sbx rm <name>`  | Kill its tmux session; move repo back; remove link.                                            |
| `sbx <name>`     | New WT window/tab → attach-or-create tmux session `<name>` at `/work/<name>` running `claude --dangerously-skip-permissions`. Starts `sbx-main` if stopped. |
| `sbx`            | Same, for the `hub` session at `/work` (orchestrator).                                         |
| `sbx ls`         | Workspace projects, their original homes, which have live tmux sessions.                       |
| `sbx sync <name> <op>` | **Host-side** git op (`push`/`pull`/`fetch`) in the project's workspace dir with host credentials. |
| `sbx rebuild`    | Confirm, then destroy and recreate `sbx-main` from `sbx:latest`.                               |
| `sbx stop`       | Stop `sbx-main`.                                                                               |
| `sbx scratch`    | v1 scratch unchanged: fresh `--rm` container, auth volume only, no workspace.                  |
| `--here` / `--tab` | As v1: current terminal / new tab instead of new window.                                     |

Retired from v1: `sbx <path>` (per-repo container), per-container `sbx stop <name>`.

## Sync / SSH — decision ladder

**v1 ships (c-lite): no keys in the container, ever.** Agents have full local
git; remote operations happen host-side via `sbx sync` (trivial wrapper —
host-side git in the workspace dir). Deliberate property: *agents commit,
human pushes* — a review gate on everything leaving the machine.

**Fast-follow research (c-heavy): SSH forced-command callback.** Host runs
OpenSSH Server; container holds a *dedicated* keypair whose `authorized_keys`
entry is pinned `restrict,command="sbx-sync-exec …"` — connections with that
key can only invoke the validator script (op ∈ {push, pull, fetch}, repo ∈
workspace), which runs host-side git with real credentials. Grants agents
autonomous sync through a *shaped* hole (three verbs on an allowlist), not
host execution. Windows probes required before trusting it: host reachability
from inside a wslc container, Win32-OpenSSH `administrators_authorized_keys`
quirk, binding/firewalling sshd away from the LAN (cf. FINDINGS P6 adjacency).

**Demoted (d): ssh-agent socket forwarding.** Hands container git the keys'
full authority (any repo, any remote) — strictly wider than the forced-command
callback. Pursue only if the callback proves insufficient.

## State: volumes and session history

- `sbx-claude-auth` unchanged at `/home/agent/.claude`; one login for
  everything including scratch.
- **`sbx-proj-*` per-repo volumes retired.** They existed because every v1
  repo mounted at the same `/work` cwd; in the unified container `/work/foo`
  vs `/work/bar` separate naturally in Claude's cwd-keyed
  `~/.claude/projects/`. Orphaned volumes are reaped (`wslc volume rm`); no
  migration of old history.
- **Long-lived per-project history is a design goal**, not a side effect: the
  central learnings store and sweep tooling depend on session
  histories/memory persisting. History survives `sbx rm` + later re-`add`
  (same `/work/<name>` key) and `sbx rebuild` (state in volume).

## Platform mapping

- **Windows:** runtime `wslc` (as v1 window/tab mode); junction-back via
  `New-Item -ItemType Junction` (no admin). Mount source: forward-slash
  Windows path (FINDINGS).
- **macOS:** runtime `docker` (OrbStack verified; `SBX_RUNTIME` honored);
  symlink-back via `ln -s`. Foreground-only constraint unchanged.
- One code path; two primitives (link creation, move). Same-volume rename
  guard on both.

## Migration

- Branch `feat/unified-workspace` off `feat/macos-port`. `sbx.ps1` keeps the
  pure-builder-function shape; per-repo mode removed; scratch and
  `--here`/`--tab` plumbing survive.
- Workspace dir auto-created on first `add`. Reap orphaned `sbx-proj-*`
  volumes. `sbx-claude-auth` untouched (no re-login).
- README, project CLAUDE.md (incl. wslc version note → 2.9.4.0),
  `verify/CHECKLIST.md` rewritten for the unified model.

## Testing

- **Unit (Pester, existing style):** `sbx-main` create-args (exactly two
  mounts); add/rm path logic (name derivation, same-volume guard,
  junction-vs-symlink by platform); tmux attach/new-session command
  construction; `sbx sync` git invocation construction. Platform-gated tests
  as in the macOS port.
- **Integration (manual checklist, replaces current):**
  1. `add` while `sbx-main` runs → visible at `/work/<name>` immediately, no
     restart; host path still works via junction.
  2. `rm` → repo back at original path, link gone, tmux session killed.
  3. History isolation: `claude --resume` in `/work/foo` vs `/work/bar` sees
     only its own sessions.
  4. `rebuild` → container replaced; workspace, auth, histories intact.
  5. Blast radius: no `~/.ssh`, no host paths beyond `/work`; scratch still
     fully isolated.
  6. `sync`: host-side push/pull works for a NAS-remoted repo.
  7. Concurrency: sessions `foo` + `hub` in two windows, both live; hub can
     edit both projects.
  8. Re-check the wslc 15-mount ceiling on 2.9.4.0 (claimed "fixed in a
     future release"); update FINDINGS either way.

## Out of scope for v2.0 (YAGNI)

- `sbx add --clone` (clone-based projects, same-repo parallelism).
- c-heavy SSH forced-command callback (fast-follow research first).
- (d) agent-socket forwarding (demoted).
- Network egress control, capability dropping — threat model unchanged.
