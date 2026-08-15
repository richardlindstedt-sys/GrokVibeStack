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

**Watch the gate in chat — never go silent.** Background `git commit` / `git push`. Do **not** wait 2–5 minutes on the bash task. Poll `gate-now.txt` every ~15s (timeout 0 or 15s). Each poll: one chat line with `RUN` + `NOW` + `ELAPSED`. Latch the new `RUN:`. Ignore stale `GATE DONE` until that RUN appears. Done only when **NOW:** contains `GATE DONE` for that RUN. UserPromptSubmit also injects a live snapshot when the user talks. No desktop popup unless `VIBE_GATE_POPUP=1`.

Deep workflow, scanner list, hook install: skill **vibe-coding** (`/vibe-coding` or skill load).
