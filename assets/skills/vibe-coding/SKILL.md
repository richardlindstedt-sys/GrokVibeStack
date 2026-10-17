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
| `Initialize-VibeRepo.ps1` | Hooks + Serena `project.yml` + thin `AGENTS.md` |
| `Get-VibeAffectedTests.ps1` | Print/run tests for this repo / changed paths |
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
- **watch** — `monitor` on `watch-gate-now.ps1 -Monitor` is the only wake. Keep it through the commit+push pair (10 min linger after GATE DONE). Speak: scan/vote/arbiter/fixer/DONE and **PROGRESS** (phase + elapsed). Never "still waiting" or "no new votes". Recap votes+arbiter+DONE before next git. Latch new `RUN:`. Kill watch after last gate of the pair. Stop is silent during a live gate and blocks once on GATE DONE. Inject includes `gate-last-done.txt`. Popup only if `VIBE_GATE_POPUP=1`.

After install: if Grok was already open → `/hooks` then `r`, or restart.

## Scanners (gate / explicit)

trivy, gitleaks, PSScriptAnalyzer, Pester, jscpd (advisory), biome, tsc (if tsconfig), markdownlint (advisory),
semgrep, ruff/mypy/bandit, vulture (advisory), yamllint/checkov, shellcheck, hadolint,
actionlint + zizmor when workflows exist, typos / golangci-lint / knip / deptry when that language is present (advisory unless the repo opted in with a config),
ast-grep project rules when `.ast-grep.yml` / `sgconfig.yml` exists, else the built-in pack (advisory),
project compile/tests if cargo/go/dotnet/pytest/npm/mvn/gradle/Pester exist
(tests on commit + Full/push; fail if a test layout exists but was skipped),
rg for TODO/FIXME/unwired.

Prefer orchestrator `run-vibe-scans.ps1` over inventing one-off commands.

## Effort, memory, worktrees

- Interactive chat effort stays **medium**. Bump **high** only for risky or multi-file work. Use plan mode first, then implement.
- One memory system per repo: **Serena project memories**. Do not also enable Grok `[memory]` / `memory_v2`, and do not turn on `/implement` memory by default.
- Risky implement runs in `spawn_subagent` with `isolation=worktree`. This skill is the only place that is documented. There is no extra script.
- Playwright and Cypress stay out of default `npm test`. Set `VIBE_RUN_E2E=1` for that opt-in. They are not part of the scanner Full pass.
- Bootstrap prints the CI twin path: copy `vibe-user-repo.yml` (scanners only, no LLM).

## Serena

- **MCP on** by default — use for find_symbol / rename / diagnostics.
- **Remind hooks off** by default — opt-in: `Enable-SerenaRemindHooks.ps1`.
