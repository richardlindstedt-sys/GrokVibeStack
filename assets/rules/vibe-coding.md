# Vibe Coding Rules (always active)

Ship solid code. Prefer quality at the **commit gate**; keep chat light.

## During chat (cheap)

1. Explore with grep / Serena / small subagents when needed — not a full panel every edit.
2. Write clean code. Prefer Serena / ast-grep for symbols over dumping whole files.
3. After logic edits: run **affected tests** (`Get-VibeAffectedTests.ps1`) and Serena/LSP diagnostics on touched paths. On-edit hooks already run secrets + linters.
4. Do **not** spawn a full multi-reviewer panel or full scanner laundry list on every change — that is what **pre-commit** is for.

## Done means

- Affected tests green (or no test runner in the repo).
- Diagnostics clean on files you touched.
- Light self-check (bugs, secrets, dead/unwired code).
- For risky / large work, optional: `vibe-review` (or wait for commit hook).
- **Commit** runs scanners + multi-reviewer (`standard` by default; docs-only may use `fast`).
- Never `--no-verify` except true emergencies.

## Full gate (on demand / hooks)

| When | What |
|------|------|
| `git commit` | pre-commit: scans + project tests (fail if skipped) + AI panel (path-aware profile) |
| `git push` | pre-push: scans + fast AI (security role if sensitive paths) |
| Explicit | `vibe-review` / `grok-ai-review.ps1 -Profile standard\|strict\|fast` |

**Watch the gate in chat.** Background commit/push. Start `monitor` on `watch-gate-now.ps1 -Monitor` when a gate starts — that is the only wake. Keep it through the commit+push pair (linger 10 min after GATE DONE). Speak: scan result, vote, arbiter, fixer file, GATE DONE, and **PROGRESS** (one line: phase + elapsed). Never "still waiting" or "no new votes". Recap votes+arbiter+DONE before next git. AWC ships this commit. **next** must be fixed in the next commit (`gate-open-advisories.json` — not auto-fixed, not droppable). **later** is ledger-only (doctor lists; no auto-fail). Latch new `RUN:`. Kill watch after last gate of the pair. Stop does not nag on wait ticks. No popup unless `VIBE_GATE_POPUP=1`.

Deep workflow, scanner list, hook install: skill **vibe-coding** (`/vibe-coding` or skill load).
