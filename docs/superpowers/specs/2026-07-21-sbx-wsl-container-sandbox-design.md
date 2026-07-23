# sbx — WSL-container sandbox for `claude --dangerously-skip-permissions`

**Date:** 2026-07-21
**Status:** Design approved; implementation not yet planned.

## Goal

Run Claude Code with `--dangerously-skip-permissions` on the Windows/ARM64 machine with a
minimal, well-understood blast radius, using the new built-in **WSL Containers**
runtime (`wslc`) — no Docker Desktop. One mechanism must serve both real-repo
work and disposable scratch experiments, and must be easy to spin up in multiple
windows at once.

## Blast radius / threat model

In scope — what we contain:

- **Destroying host files / OS.** A rogue or mistaken command must not be able to
  reach `C:\`, the Windows host, or any file outside the one repo being worked on.
- **Touching the wrong repos.** Other git repos on the machine must be *absent*
  from the container's filesystem, not merely "not modified."

Explicitly out of scope (confirmed with user):

- **Network egress / exfiltration control.** Not hardened. Containers have normal
  network access so `npm install`, tool downloads, and Claude's API calls work.
- **Credential theft in general.** Not a primary concern — but see SSH below,
  which is kept opt-in specifically to avoid *casually* exposing keys.

The intended writable surface for a real-repo run is exactly one directory: the
mounted repo. Worst-case damage = wiping/corrupting that repo, which is
git-recoverable and is the thing being worked on anyway.

## Architecture

Three components, all living in `~/src/sbx`:

1. **Sandbox image** — built once with `wslc build` from a `Sandboxfile`
   (OCI/Dockerfile-compatible). Contains:
   - Debian base + Node (LTS)
   - Claude Code (`npm i -g @anthropic-ai/claude-code`)
   - `git`, `tmux`, `ripgrep`, `curl`, `openssh-client`
   - A non-root `agent` user (uid 1000), home `/home/agent`, `WORKDIR /work`
   - `tmux` is present *inside* so a single window can host multiple Claude
     sessions on its one mounted repo — this covers the "same repo, parallel"
     case without any worktree machinery.

2. **`sbx` launcher** — a PowerShell function loaded from the user's `$PROFILE`
   (thin; the real logic can live in a script in this repo that the profile dot-
   sources). It composes and runs the `wslc run` invocation and, by default,
   opens a new Windows Terminal window for it.

3. **Persistent auth volume** — a named `wslc` volume mounted at
   `/home/agent/.claude`, so the user logs Claude in once and every future
   container reuses that login. This is the **only** host-adjacent state a
   default container sees — no SSH keys, no `~/.aws`, no `C:\`.

## Command surface

| Invocation           | Behavior                                                                                          |
| -------------------- | ------------------------------------------------------------------------------------------------- |
| `sbx <path>`         | New WT window → container with **only** `<path>` mounted at `/work` → `claude --dangerously-skip-permissions`. |
| `sbx`                | New WT window → **scratch**: `--rm`, no host mount, discarded on exit.                             |
| `sbx --here <path>`  | As above but runs in the current terminal instead of spawning a window.                           |
| `sbx --tab <path>`   | Spawn as a new WT **tab** instead of a new window.                                                 |
| `sbx --ssh <path>`   | Additionally bind-mount `~/.ssh` **read-only** into the container (for NAS-hosted git remotes).    |
| `sbx --name <n> …`   | Override the auto-generated container name.                                                        |
| `sbx ls`             | Wraps `wslc ps`, filtered to `sbx-*` — see what's live.                                            |
| `sbx stop <name>`    | Stop/remove one sandbox.                                                                           |

Defaults: **new window** (not tab); no SSH; auth volume always mounted.

Container naming: real runs are named `sbx-<repo-basename>-<short-rand>` so
`sbx ls` is readable and names never collide across concurrent windows.

## Isolation properties (mapped to the threat model)

- *Destroy host FS/OS* → the container root filesystem is separate from the host;
  the only host path present is the single mounted repo (plus the `.claude`
  volume, and `~/.ssh` read-only on `--ssh` runs). There is no path from inside
  the container to `C:\` or the Windows OS.
- *Touch wrong repos* → other repos are simply **not in the filesystem**. Nothing
  to wander into; nothing to block.

## SSH handling (NAS repos)

Some repos are hosted on the user's NAS over SSH rather than GitHub, so git
operations there need key access.

- **v1 (this spec): read-only `~/.ssh` bind mount**, gated behind `--ssh`.
  Reliable on preview `wslc`. The private key file is present (read-only) inside
  the container only for the duration of that flagged run. Default and scratch
  runs never see it.
- **v2 (future): ssh-agent forwarding.** Forward the agent socket so key
  *material* never enters the container. More aligned with minimal blast radius,
  but depends on an ssh-agent reachable from WSL (likely a Windows→WSL agent
  bridge) and may be fiddly on preview `wslc`; deferred until the base sandbox is
  proven.

## Orchestration model

The user's concern was easily running multiple windows. Resolution:

- **Across repos (primary):** each `sbx <path>` call = one new WT window = one
  container on one distinct repo. Different repos ⇒ different mounts ⇒ no
  collision. Run it N times → N side-by-side windows, N isolated sandboxes. No
  orchestrator daemon; `sbx ls` provides visibility.
- **Within one repo:** `tmux` inside that window (the image ships it), matching
  the user's existing habit of navigating multiple sessions in one window.

Two containers must **not** mount the same host repo (their edits would clobber
each other) — the workflow above avoids this by construction, and same-repo
parallelism is handled inside one container via tmux instead.

## Known risk — verify before building

`wslc` is in **public preview** (build 2.9.3; GA targeted fall 2026). The one
thing not guaranteed from documentation is **bind-mount path syntax** — whether
`-v` expects a Windows path (`C:\Users\...`), a WSL path (`/mnt/c/...`), or a
distro-local path, and how that interacts with known MSYS / native-Windows-binary
path quirks on this machine.

**First implementation step is an empirical probe**, before building anything on
top:

```
wslc run --rm -v <candidate-path>:/work <base-image> ls -la /work
```

Try each candidate form until one correctly lists the host directory's contents.
Record the winning form; the launcher's path translation is built around it. If
mounts prove unworkable on preview `wslc`, the documented fallback is a
locked-down dedicated WSL2 distro (automount disabled) — so the project is not
blocked on the preview feature.

## Testing / verification strategy

- **Isolation:** inside a running sandbox, confirm `/` contains no host `C:` and
  that a *different* known repo path does not exist; confirm the mounted repo IS
  writable.
- **Scratch cleanup:** `sbx` (no arg) leaves no container after exit (`--rm`).
- **Concurrency:** two `sbx <different-repo>` windows run simultaneously, each
  sees only its own repo, `sbx ls` lists both distinctly.
- **Auth persistence:** log in once; a later fresh container is already
  authenticated via the `.claude` volume.
- **SSH gating:** `--ssh` run can reach the NAS remote; a default run cannot see
  `~/.ssh` at all.

Concrete test tooling/framework for this repo (pytest vs. bats vs. plain script)
is deferred to the implementation-planning step, per the project's new-repo
routine (build/test/branch conventions still to be set).

## Out of scope for v1 (YAGNI)

- ssh-agent forwarding (v2, above).
- A `git clone <url>` scratch variant — deferred unless a concrete need appears.
- Network egress restrictions, capability dropping, read-only root — deliberately
  omitted given the threat model.

## References

- WSL container public preview — Microsoft DevBlogs:
  https://devblogs.microsoft.com/commandline/wsl-container-is-now-available-for-public-preview/
- WSL containers overview — Help Net Security:
  https://www.helpnetsecurity.com/2026/06/30/microsoft-linux-wsl-containers/
- `wslc` Docker-like CLI — Linuxiac:
  https://linuxiac.com/wsl-gets-its-own-linux-container-runtime-with-docker-like-commands/
