# Vibe Coding Rules (always active)

You are doing "vibe coding": produce code that feels excellent because it has been rigorously reviewed by you (the AI) using every available tool and subagent.

## Mandatory Process for Any Code Change

1. **Exploration** — Use the explore subagent (or rg + fd + ast-grep) before making big changes.
2. **Planning** — For anything > ~30 lines or architectural, use the plan subagent first.
3. **Implementation** — Write the code cleanly.
4. **Self-Review loop (NON-NEGOTIABLE)**:
   - Immediately after writing, run relevant scanners via the installed tools (see below).
   - Prefer the full gate: `vibe-review` / `grok-ai-review.ps1` which runs:
     • **3 independent reviewers** — correctness, security, simplicity
     • **Arbiter** — merges findings; resolves blocker vs advisory disputes
     • **Fix pass** on blockers → **re-review** (up to 3 rounds)
   - In-session, also spawn reviewer + security-auditor when not running the full gate.
   - Critically analyze for bugs, secrets, duplication, dead/unwired code, bad errors, missing tests.
5. Only when the multi-reviewer loop passes (no remaining blockers) consider the task complete.

## Tools You Must Use

- trivy fs . --scanners vuln,secret,misconfig
- gitleaks detect
- PSScriptAnalyzer (PowerShell) via Invoke-ScriptAnalyzer
- Pester (PowerShell tests) via Invoke-Pester when *.Tests.ps1 exist
- jscpd (duplication)
- biome check (web projects)
- markdownlint (Markdown/docs)
- semgrep scan
- ruff + mypy + bandit + vulture (Python)
- yamllint + checkov (YAML/IaC)
- shellcheck (shell)
- hadolint (Dockerfiles)
- rg for TODO/FIXME/unwired hints + ast-grep when available

## Commit Discipline

When the user (or you) are about to commit:
- The pre-commit hook runs scanners + the multi-reviewer panel/arbiter/fix loop on staged changes.
- Blockers are auto-fixed and re-reviewed when possible; remaining blockers block the commit.
- Never bypass with `--no-verify` except true emergencies.

## Subagent Usage

Default to spawning subagents for:
- Any search of the codebase -> explore
- Design or multi-file work -> plan
- Writing implementation -> implementer (but you still review)
- Every piece of code you produce -> reviewer + security-auditor

You are not done until the reviewer has had its say on your work.