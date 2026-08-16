# Vibe Coding Rules (always active)

Ship solid code. Prefer quality at the **commit gate**; keep chat light.

## During chat (cheap)

1. Explore with grep / Serena / small subagents when needed — not a full panel every edit.
2. Write clean code. Prefer Serena / ast-grep for symbols over dumping whole files.
3. After non-trivial edits: quick self-check (bugs, secrets, dead/unwired code). On-edit hooks already run fast linters/secrets.
4. Do **not** spawn a full multi-reviewer panel or full scanner laundry list on every change — that is what **pre-commit** is for.

## Done means

- You did a light self-check on what you touched.
- For risky / large work, optional: `vibe-review` (or wait for commit hook).
- **Commit** runs scanners + multi-reviewer (`standard` by default; docs-only may use `fast`).
- Never `--no-verify` except true emergencies.

## Full gate (on demand / hooks)

| When | What |
|------|------|
| `git commit` | pre-commit: scans + AI panel (path-aware profile) |
| `git push` | pre-push: scans + fast AI (security role if sensitive paths) |
| Explicit | `vibe-review` / `grok-ai-review.ps1 -Profile standard\|strict\|fast` |

**Watch the gate in chat — never go silent.** Background `git commit` / `git push`. Start `monitor` on `watch-gate-now.ps1 -Monitor` when a gate starts (prints RUN/NOW/ELAPSED; GATE DONE is a tick, not exit). Leftover `GATE DONE` at startup does **not** kill the watch. After a live gate, watcher lingers ~45s on that RUN's `GATE DONE`, then prints `DONE` and exits. After the last gate of the pair, **kill the watch**. If the next gate starts and the watch is already dead, start a new one. Do **not** wait 2–5 minutes on bash. Poll `gate-now.txt` every ~15s (`timeout_ms` 0 or 15000 — live-gate PreToolUse clamps longer waits). Each poll: one chat line `RUN` + `NOW` + `ELAPSED`. Latch the new `RUN:`. Ignore stale `GATE DONE` until that RUN appears. A gate is done when **NOW:** contains `GATE DONE` for that RUN. Stop hook blocks a silent end while the gate is live. UserPromptSubmit injects a snapshot when the user talks. No desktop popup unless `VIBE_GATE_POPUP=1`.

Deep workflow, scanner list, hook install: skill **vibe-coding** (`/vibe-coding` or skill load).
