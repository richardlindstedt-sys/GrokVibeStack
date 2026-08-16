---
name: vibe-coding
description: >
  High-quality vibe coding: when to use subagents, scanners, and the multi-reviewer
  gate. Full panel is for commit hooks / explicit vibe-review — not every chat turn.
  Use when implementing non-trivial work, installing hooks, or running quality gates.
user-invocable: true
---

# Vibe Coding Skill (deep / on-demand)

Always-on **rules** stay short. This skill is the full playbook.

## Chat vs gate

| Layer | Expectation |
|-------|-------------|
| Chat / edits | Light self-check; on-edit hooks; Serena for symbols |
| Before "done" on large work | Optional `run-vibe-scans` or `vibe-review` |
| `git commit` | Hook: scans + multi-reviewer (path-aware profile) |
| `git push` | Hook: scans + fast AI (+ security if sensitive; **version tags → strict**, single-commit) |

Do **not** re-run a full 3-reviewer panel in-session when pre-commit will run standard — that doubles token cost for little gain.

## When you want the full process

1. Explore (grep / Serena / explore subagent) for non-trivial work.
2. Plan if architectural or multi-file.
3. Implement cleanly.
4. Self-check; optional `run-vibe-scans.ps1`.
5. Explicit full gate when needed:
   `vibe-review` or `& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile standard`

## Profiles

| Profile | Roles | Effort | Typical |
|---------|-------|--------|---------|
| **fast** | correctness (+ security if sensitive paths on push) | medium | push, docs-only commit |
| **standard** | correctness + security + simplicity | high | pre-commit default |
| **strict** | same as standard, more rounds | high | high-risk / version-tag push / release |

Path-aware: docs/md-only → fast; sensitive paths (`auth`, `hook`, `crypto`, …) keep/add security.

## Orchestrators

| Tool | When |
|------|------|
| `run-vibe-scans.ps1` | Static scanners (`-Scope Auto\|Staged\|Full`) |
| `vibe-review` / `grok-ai-review.ps1` | Multi-reviewer + fix loop |
| `install-vibe-hooks.ps1` | Once per repo |
| `doctor.ps1` | Health + latest report |
| `Invoke-VibeStackSmoke.ps1` | Offline smoke (no AI) |
| `run-vibe-evals.ps1` | Known-bad plants (must fail closed) |

## Hook install (per repo)

If `.git` exists and hooks missing `Vibe pre-`:

```powershell
& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" .
```

- **pre-commit** — scans (staged-first) + AI (`-AutoProfile`, default base standard)
- **pre-push** — scans (full / cache) + AI fast (version tags → strict, parent..tip)
- **on-edit** — global PostToolUse fast checks; findings injected on next `UserPromptSubmit`
- **watch** — poll `~/.grok/vibe-tools/reports/gate-now.txt` every ~15s (PreToolUse clamps longer waits). Speak `RUN`+`NOW`+`ELAPSED` plus new scan/reviewer/arbiter `EVT` lines each poll. Do not leave the user on the first scan line. Start `monitor` on `watch-gate-now.ps1 -Monitor` when a gate starts (GATE DONE is a tick, not exit). Leftover `GATE DONE` at startup does **not** kill the watch. After a live gate, watcher lingers ~45s on that RUN's `GATE DONE`, then prints `DONE` and exits. After the last gate of the pair, **kill the watch**. If the next gate starts and the watch is already dead, start a new one. Stop hook blocks a silent end while the gate is live, and after a fresh `GATE DONE` until chat recapped that RUN (votes + DONE). Speak the full recap before the next git command. Latch the new `RUN:` line; ignore leftover `GATE DONE` until that RUN appears. UserPromptSubmit also injects `gate-last-done.txt` so a new RUN cannot hide the last panel. Popup only if `VIBE_GATE_POPUP=1`.

After install: if Grok was already open → `/hooks` then `r`, or restart.

## Scanners (gate / explicit)

trivy, gitleaks, PSScriptAnalyzer, Pester, jscpd, biome, markdownlint (advisory),
semgrep, ruff/mypy/bandit/vulture, yamllint/checkov, shellcheck, hadolint,
rg for TODO/FIXME/unwired.

Prefer orchestrator `run-vibe-scans.ps1` over inventing one-off commands.

## Serena

- **MCP on** by default — use for find_symbol / rename / diagnostics.
- **Remind hooks off** by default — opt-in: `Enable-SerenaRemindHooks.ps1`.
