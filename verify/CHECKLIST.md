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
   `sbx ls` after exit; no `/work` inside. A SECOND consecutive scratch has an
   EMPTY `/resume` menu (per-run `<container>-proj` volume isolates it from hub
   and prior-scratch history — both key on cwd `/work`), and no
   `sbx-scratch-*-proj` volume lingers in `wslc volume list` after exit.
9. **Concurrency:** windows on `foo` + hub simultaneously; hub edits a file in
   `/work/foo`, project session sees it instantly.
10. **wslc 15-mount ceiling re-check (2.9.4.0):** after the runs above, note
    whether the "Too many volumes (limit: 15)" error still occurs on repeated
    scratch launches; update docs/FINDINGS.md either way.
