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

Deep workflow, scanner list, hook install: skill **vibe-coding** (`/vibe-coding` or skill load).
