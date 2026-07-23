# sbx-agent-status — fleet oversight for stage 7

## The problem

At 3-5 agents you hold the fleet in your head. At 10+ you can't, and the dominant
failure mode is agents silently stalled while you believe they're working. Yegge's
own stage-7 line is that coordination failures emerge "without systematic oversight."
This is the oversight.

## Two rules

**1. Eliminate stalls before detecting them.** Running under
`--dangerously-skip-permissions` already deletes the largest class (permission
prompts). What remains:

- **Clarifying questions** — the agent asking which approach you want. Fix upstream
  with a tighter spec before launch. Every decision pre-made is a stall that never
  happens.
- **Finished-and-idle** — not a stall, but externally identical to one.
- **Wedged / looping / crashed** — needs real liveness detection.

**2. Pull aggregate, don't push per-agent.** Ten agents each pushing a notification
is notification fatigue, not oversight — you start ignoring them around agent four.
One glance covering ten is what scales. Reserve push notifications for *aggregate*
conditions ("4 sessions stale >10min"), so it's one alert instead of ten.

## Architecture: hooks are authoritative, tmux is the cross-check

**Primary — hooks.** Claude Code's **Notification** hook fires exactly when the agent
needs input; the **Stop** hook fires when it finishes a turn. Have both write a small
state file into the shared workspace:

    /work/.sbx/status/<session>.json   →  { state, project, last_activity }

`sbx status` then just reads that directory. The v2 unified workspace is what makes
this cheap — one filesystem every session can write to. v1's isolated per-repo
containers would have needed real plumbing for the same thing.

**Secondary — `sbx-agent-status.sh`.** Needs no agent cooperation, and catches the
case hooks structurally cannot: an agent that died *without ever firing a hook*.

## The hard limit (do not paper over this)

**Nothing external can distinguish "waiting for input" from "working quietly."** An
agent blocked on a question and an agent eight minutes into a build both emit no
output. That ambiguity is not solvable with cleverness at the tmux layer — it's why
the Notification hook is the authoritative signal and this script is a cross-check.

`pane_title` is suggestive (Claude sets it to its live status line, e.g.
`⠂ Verify expected behavior`), but only the *working* state has been observed. Watch
what it renders when an agent actually blocks before building a matcher on it.

## Correction: why `pane_current_command` does not work

The first version of this script keyed on `#{pane_current_command}`, expecting
`claude` vs `bash`. It reports `bash` for a live agent. Observed tree:

    bash(1909) → start_bot.sh(135191) → claude(135192)

`claude` is a real named process, but it sits two levels below the pane shell, so it
never becomes the tty's foreground process group and tmux samples the shell. **Any**
wrapper script does this — including sbx's own launcher, so this would have failed
inside the sandbox too.

The fix is to descend the process tree: build `pid → ppid` once from a single `ps`
call, mark every ancestor of every `claude` process, then test each pane's pid against
that set. One `ps` regardless of session count, and portable across Linux procps and
macOS BSD `ps`.

## The notify-ntfy trap

The existing `notify-ntfy` hooks are scoped to **permission prompts**. Inside sbx
there are none — that's the entire point of the sandbox. Those hooks go silent in the
box, and silence reads as "all ten are working." Re-scope them to the Notification and
Stop hooks generally, or the oversight you think you have is a no-op exactly where you
need it.

## Usage

    ./sbx-agent-status.sh              # stalest first
    SBX_IDLE_WARN=5 ./sbx-agent-status.sh    # flag anything idle >= 5 min

Sample:

    bot:0            idle=   0m  claude  ⠂ Verify expected behavior
    bot:1            idle=   0m  shell   remote-box-01

Put it where you'll actually look — the hub session at `/work`:

    watch -n5 ./sbx-agent-status.sh

## Note

Building this aggregator is the first component of a stage-8 orchestrator. Stage 7 is
the rung you're meant to hate enough to escape; assignment logic, task queues, and
checkpointing are what's on the other side.
