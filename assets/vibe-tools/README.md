# Grok Build - Vibe Coding Tools & Self-Review

High-quality "vibe coding": Grok writes code, then a **multi-reviewer panel** argues severity, an **arbiter** decides blockers vs advisories, and a **fix → re-review loop** runs until clean (or max rounds).

## Installed Tools
- Trivy           → vulns, secrets, misconfigs, SAST (`trivy fs .`)
- Gitleaks        → secrets (`gitleaks detect`)
- PSScriptAnalyzer → PowerShell lint/static analysis (Invoke-ScriptAnalyzer)
- Pester          → PowerShell tests (`Invoke-Pester`)
- jscpd           → duplicate code (`jscpd .`)
- Biome           → JS/TS/JSON lint + format (`biome check .`)
- prettier / eslint / tsc → JS/TS format + lint + types (global npm)
- markdownlint-cli→ Markdown/docs quality
- Semgrep         → multi-lang rules + security (`semgrep scan`)
- Ruff + Vulture  → Python lint + dead code
- mypy + bandit   → Python types + security
- yamllint + checkov → YAML + IaC / cloud security
- ShellCheck      → shell scripts
- Hadolint        → Dockerfiles
- ast-grep (`sg`) → structural code search/rewrite
- gh              → GitHub CLI (PRs, issues, checks)
- Serena MCP      → symbolic nav/edit (`find_symbol`, rename, diagnostics)
- Git             → commit hooks

Scanner binaries live in `~\.grok\vibe-tools\venv\Scripts` (also on user PATH).
Serena CLI: `~\.local\bin\serena.exe` (MCP wired in `~\.grok\config.toml`).

## Orchestrators (what they do)

| Command | Role |
|---------|------|
| `vibe-review` / `vibe-tools\vibe-review.ps1` | **Full gate**: scans + multi-reviewer loop (default **profile=standard**). |
| `scripts\run-vibe-scans.ps1` | **Scanners only** (trivy, gitleaks, biome, ruff, semgrep, …). Fast; no AI. |
| `scripts\grok-ai-review.ps1` | Canonical multi-reviewer loop (used by vibe-review + git hooks). |
| `scripts\Invoke-VibeStackSmoke.ps1` | Offline smoke (parse, profiles, doctor, optional temp hooks). |
| `install-vibe-hooks.ps1` / `install-pre-commit-hook.ps1` | Installs **pre-commit** + **pre-push** git hooks and global Grok **on-edit** hook. |

### Gate profiles

| Profile | Reviewers | Max rounds | Fix loop | Used by |
|---------|-----------|------------|----------|---------|
| `fast` | correctness only | 1 | off | **pre-push** |
| `standard` | correctness, security, simplicity | 2 | on | **pre-commit**, default `vibe-review` |
| `strict` | same as standard | 3 | on | manual / release |

Env: `VIBE_GATE_PROFILE`, `VIBE_GATE_NO_CACHE=1`.

### Multi-reviewer loop (what makes this different)

```text
static scans
    → reviewer panel (profile roles; parallel unless Sequential/fast)
    → arbiter merges findings, resolves blocker vs advisory disputes
    → if blockers: implementer fixes → re-stage → re-review (until max rounds)
    → pass only on APPROVE / STRONG_APPROVE / APPROVE_WITH_CHANGES
    → write reports/ + update diff-hash pass cache
```

| Flag | Effect |
|------|--------|
| `-Profile fast\|standard\|strict` | Role set, rounds, default NoFix/parallel |
| (default) | **standard**: full loop with auto-fix |
| `-NoFix` | Panel + arbiter only (block on blockers; no implementer) |
| `-MaxRounds N` | Cap fix/re-review rounds (0 = profile default) |
| `-SequentialReviewers` | Run reviewers one-by-one (debug; default parallel except fast) |
| `-NoCache` / `-NoReport` | Skip pass cache or report files |

**Reports:** `~\.grok\vibe-tools\reports\latest.md` (+ `latest.html`, `latest.json`).  
**Cache:** identical diff hash + profile + model + repo that already PASSED skips AI (`cache/gate-pass-cache.json`).

Grok should still use in-session subagents; the **git gate enforces** the panel loop on commit/push.

## Always-on Behavior (via rules)
Grok must:
1. Use subagents heavily (reviewer, security-auditor, explore, plan, implementer).
2. After writing code, run relevant scans (`run-vibe-scans.ps1` or targeted tools).
3. Always perform a full self-review (via reviewer subagent or `vibe-review` / `grok-ai-review.ps1`) of its own changes.
4. Prefer Serena MCP for symbol-level navigation when available (activate project if needed).
5. Look specifically for: duplication, dead code, unwired/incomplete features, security issues, bugs.

## Using the Tools Manually
```powershell
# Full vibe review (scans + AI) — default profile=standard
vibe-review
& "$env:USERPROFILE\.grok\vibe-tools\vibe-review.ps1"
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile fast
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile strict

# Static scans only
& "$env:USERPROFILE\.grok\vibe-tools\scripts\run-vibe-scans.ps1"

# Latest gate report
Get-Content "$env:USERPROFILE\.grok\vibe-tools\reports\latest.md"

# Offline smoke (no AI)
& "$env:USERPROFILE\.grok\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1" -WithHooksInstall
```

## Per-Repository Gates (edit + commit + push)
Run this in every project you want protected:

```powershell
& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" .
# or:
install-vibe-hooks.ps1 .
```

| Gate | When | What runs | Blocks? |
|------|------|-----------|---------|
| **On edit** | Grok `PostToolUse` after `search_replace` / write | `run-vibe-on-edit.ps1` — secrets heuristics, gitleaks, ruff/biome/PSSA/shellcheck on touched file | No (reports in scrollback) |
| **pre-commit** | `git commit` | Full scanners + **profile=standard** loop on **staged** diff | Yes |
| **pre-push** | `git push` | Full scanners + **profile=fast** loop on **push range** | Yes |

Also deletes inert `*.sample` hooks from `.git/hooks/`.

If Grok was already open during install: `/hooks` then `r`, or restart. New sessions load hooks automatically.

Emergency bypass only: `git commit --no-verify` / `git push --no-verify`.

**Grok will remind you** (via the `vibe-coding` skill) if this repo is missing the vibe pre-commit hook.

## Recommended Workflow (inside Grok)
- Ask Grok to implement something.
- Grok should:
  1. Use explore subagent if needed.
  2. Use plan subagent.
  3. Implement.
  4. Run scans.
  5. Spawn reviewer + security-auditor (or run `vibe-review` for the full panel loop).
  6. Only then present final result. Commit runs the same loop again via pre-commit.

## Disable / Tone Down
- Remove the pre-commit hook: `rm .git/hooks/pre-commit`
- Edit `~/.grok/rules/vibe-coding.md`
- Say "normal mode" to drop caveman if combined with token stack.