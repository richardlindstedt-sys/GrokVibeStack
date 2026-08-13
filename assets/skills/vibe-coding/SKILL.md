---
name: vibe-coding
description: >
  High-quality "vibe coding" workflow. Always use subagents (explore/plan/implementer/reviewer/security-auditor),
  run scanners after writing code, and run the multi-reviewer fix/re-review gate (vibe-review) on your own output.
  Pre-commit enforces the same panel loop on every commit.
user-invocable: true
---

# Vibe Coding Skill (always-on expectations)

You are operating under the **vibe-coding** discipline.

## Core Requirements (never skip)
1. Use subagents by default for any non-trivial work.
2. After generating or editing code, run relevant scanners — prefer orchestrator:
   `& "$env:USERPROFILE\.grok\vibe-tools\scripts\run-vibe-scans.ps1"`
   (or targeted: trivy, gitleaks, jscpd, semgrep/ruff/biome, mypy/bandit, etc.).
3. Always do a rigorous self-review of your own changes:
   - in-session: reviewer + security-auditor subagents
   - full gate: `vibe-review` — default **profile=standard** (3 reviewers → arbiter → fix → re-review);
     reports under `~/.grok/vibe-tools/reports/latest.md`. Profiles: `fast` | `standard` | `strict`.
4. Prefer **Serena MCP** for symbol-level find/rename/diagnostics when tools are available;
   activate project if needed ("activate current dir as Serena project").
5. Explicitly hunt for: duplication, dead code, unwired/incomplete features ("not wired"), security issues, and bugs.

## Orchestrators (use these — don't reinvent)

| Tool | When |
|------|------|
| `run-vibe-scans.ps1` | After code changes — static scanners only |
| `vibe-review` / `grok-ai-review.ps1` | End of non-trivial work or before commit — multi-reviewer + fix loop (`-Profile`) |
| `install-vibe-hooks.ps1` | Once per repo — **pre-commit=standard** + **pre-push=fast** + global **on-edit** |
| `doctor.ps1` | Proxy/hooks/latest report health |
| `Invoke-VibeStackSmoke.ps1` | Offline stack smoke (no AI) |

## Pre-Commit Hook Check (MANDATORY)

**Every time you start working in a directory that looks like a project (especially if you see .git, package.json, *.py, *.rs, etc.):**

- Check whether vibe hooks are installed:
  Look for `.git/hooks/pre-commit` and `.git/hooks/pre-push` containing "Vibe pre-".

- If missing, you **must** tell the user immediately and offer:

  ```powershell
  & "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" .
  ```

  That installs:
  - **pre-commit** — scanners + **profile=standard** fix/re-review loop on staged diff (blocks)
  - **pre-push** — scanners + **profile=fast** (1 correctness reviewer) on push range (blocks)
  - **on-edit** — global Grok `PostToolUse` fast checks after file edits
  - removes inert `*.sample` hooks

- Strongly recommend installing for any serious work. Only skip if user says "no hook".

- After install: "Vibe hooks live. Edit → fast checks. Commit → standard gate. Push → fast gate. If Grok was already open, reload once (/hooks → r) or restart; new sessions auto-load."

## Available Commands

- Full multi-reviewer loop (scans + panel + fix/re-review, profile standard):  
  `vibe-review`  
  or `& "$env:USERPROFILE\.grok\vibe-tools\vibe-review.ps1"`  
  Fast / strict / review-only:  
  `& "...\grok-ai-review.ps1" -Profile fast`  
  `& "...\grok-ai-review.ps1" -Profile strict`  
  `& "...\grok-ai-review.ps1" -NoFix`

- Install hooks in current repo:  
  `& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" .`

- Just the scanners:  
  `& "$env:USERPROFILE\.grok\vibe-tools\scripts\run-vibe-scans.ps1"`

- Symbolic code tools: Serena MCP (`serena` / `mcp_servers.serena` in `~/.grok/config.toml`)

## When the user asks you to implement, code, or "do vibe coding"
- Follow the full process above.
- After non-trivial edits, run `run-vibe-scans.ps1` (or `vibe-review` for the full gate).
- If you are about to suggest a commit or the user runs `git commit`, remind them about the hook if it is missing.

Never treat "I wrote some code" as complete until scans + self-review have happened.