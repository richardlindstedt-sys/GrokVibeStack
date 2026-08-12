# Grok Vibe Stack Bootstrap

Portable **install / uninstall** for maximum **quality gates** + maximum **token savings** on Windows Grok Build.

Target machine: **only Grok Build CLI installed**. This repo installs everything else.

## Design goals

| Goal | How |
|------|-----|
| **Quality** | On-edit checks · scanners · **3-reviewer panel + arbiter + fix/re-review loop** (fail-closed) |
| **Token savings** | Headroom max-coding profile · RTK auto-enforce · caveman · early compact · MCP caps |
| **Fresh machines** | Installer always applies **all** gates + max-savings settings (no watered-down default) |

## What gets installed

### Quality gates

| Gate | Trigger | Action | Blocks? |
|------|---------|--------|---------|
| On-edit | Grok file write/edit | Secrets + linters on touched file | No (report) |
| **pre-commit** | `git commit` | Scanners + **profile=standard** multi-reviewer loop on staged diff | **Yes** (fail-closed) |
| **pre-push** | `git push` | Scanners + **profile=fast** (1 correctness reviewer) on push range | **Yes** (fail-closed) |
| Stop reminder | Turn end | Remind if review skipped | No |

### Multi-reviewer quality loop (core innovation)

```text
scans → reviewer panel (profile roles) → arbiter → blockers? fix → re-review
      → APPROVE* passes · BLOCK after max rounds fails closed
      → MD/HTML report under ~/.grok/vibe-tools/reports/
      → diff-hash pass cache (same diff+profile+model can skip AI)
```

| Profile | Roles | Rounds | Fix loop | Typical use |
|---------|-------|--------|----------|-------------|
| **fast** | correctness | 1 | off | pre-push (cheap second gate) |
| **standard** | correctness + security + simplicity | 2 | on | pre-commit, `vibe-review` default |
| **strict** | same as standard | 3 | on | release / high-risk; higher turn budgets |

```powershell
vibe-review                          # standard
& ...\grok-ai-review.ps1 -Profile fast
& ...\grok-ai-review.ps1 -Profile strict
$env:VIBE_GATE_PROFILE = 'strict'    # override default
$env:VIBE_GATE_NO_CACHE = '1'        # disable pass cache
```

- **Fail-closed:** missing grok/proxy, unparseable panel/arbiter, or leftover blockers → block  
- **Advisories** (`APPROVE_WITH_CHANGES`) do not block; **blockers** do  
- Review-only: `grok-ai-review.ps1 -NoFix` (also default for **fast**)  
- Reports: `~\.grok\vibe-tools\reports\latest.md` (+ `.html` / `.json`)  
- Scanners are **read-only** (Biome never auto-writes in gates)  
- **Serena remind hooks OFF by default** (they fired on every `read_file` and showed `hooks: N failed`). Serena **MCP** still installed. Opt-in: `Enable-SerenaRemindHooks.ps1`

**Git hooks are per-repo.** Install cwd gets them; other repos need `install-vibe-hooks.ps1` once each.

### Token savings (max profile)

| Layer | Setting |
|-------|---------|
| Headroom proxy | `--mode token --lossless --code-aware --intercept-tool-results --target-ratio **0.35** --no-ccr-proactive-expansion --read-maturation` |
| Env profile | `HEADROOM_SAVINGS_PROFILE=coding` + dedupe, tool-search, protect-reads, min_tokens=25 |
| RTK | Auto-**deny** bare noisy shell (`run-rtk-enforce.ps1`); must use `rtk …` |
| Caveman | `ultra` chat output |
| Compact | **55%** threshold + two-pass |
| MCP | `max_output_bytes = **20000**` |
| Interactive effort | `default_reasoning_effort = **medium**` (saves tokens) |
| Gate effort | Multi-reviewer loop forced **`--reasoning-effort high`** |

**Not enabled by default** (quality/loop risk): Headroom `--memory` / `--learn`, `HEADROOM_OUTPUT_SHAPER`, profile `agent-90` (too lossy on system prompts).

### Tools

| Source | Packages |
|--------|----------|
| winget | Python, Git, Node, uv, ripgrep, fd, bat, trivy, gitleaks, biome, shellcheck, hadolint, gh, **jq** |
| npm | jscpd, markdownlint-cli, prettier, eslint, typescript |
| pip venvs | headroom-ai, ast-grep, ruff, mypy, bandit, semgrep, checkov, yamllint, vulture |
| headroom tools | **difft**, scc, ast-grep cache |
| other | rtk, Serena MCP, PSScriptAnalyzer, Pester 5+ |

## Install

```powershell
cd path\to\this\repo
Set-ExecutionPolicy -Scope Process Bypass
.\Install-GrokVibeStack.ps1
```

### Flags (opt-out only — default is max)

| Flag | Effect |
|------|--------|
| `-DryRun` | Plan only |
| `-SkipWinget` | Skip optional scanner CLIs (still installs Python/Git/Node/uv) |
| `-SkipNpm` | Skip npm globals |
| `-SkipSerena` | Skip Serena |
| `-SkipRepoHooks` | **Not recommended** — skips git quality gates in cwd |
| `-SkipPythonInstall` / `-SkipGitInstall` / `-SkipNodeInstall` | Skip that prereq auto-install |
| `-UseFrozenReqs` | Optional pip freeze pins (not default) |

### After install

```powershell
# new terminal (PATH refresh)
start-grok -Status
start-grok

# In Grok TUI — REQUIRED or RTK/on-edit stay inactive for this session:
/hooks
# then press r
```

Default model is `grok-via-headroom` (needs proxy on `127.0.0.1:8787`). Prefer `start-grok` over bare `grok`.

Other repos (git quality gates):

```powershell
& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" .
```

### Permissions note

This stack **does not** set `permission_mode = "always-approve"`. If tools auto-run without prompts, check Grok `/settings` — that is separate from vibe/token install. `doctor.ps1` warns if always-approve is present.

## Uninstall

```powershell
.\Uninstall-GrokVibeStack.ps1
.\Uninstall-GrokVibeStack.ps1 -Force
.\Uninstall-GrokVibeStack.ps1 -DryRun
```

Keeps Grok Build (`grok.exe`, `auth.json`, sessions). Removes only stack-owned files:

- `~\.grok\token-saving\`, `~\.grok\vibe-tools\`
- Named hooks/rules/skills the stack installed (not entire `skills/` or `hooks/` trees)
- PATH entries recorded in the install manifest (never strips `~\.grok\bin` while Grok lives there)

Optional: `-RemoveWingetPackages`, `-RemoveNpmPackages`, `-RemoveSerena`, `-RemovePython` (only if stack installed them), etc.

## Expected savings vs vanilla Grok

| Layer | Typical effect |
|-------|----------------|
| Headroom @ 0.35 keep-ratio + coding profile | Often **tens of %** on long sessions; more on log/JSON-heavy turns |
| RTK (enforced) | Large cut on noisy command **stdout** when used consistently |
| Caveman + medium effort | Fewer **output** / thinking tokens day-to-day |
| Compact @ 55% | Fewer giant multi-hour contexts |

Gates (commit/push AI review) **spend** tokens on purpose for quality.

Check live: `headroom savings` · `rtk gain` · `start-grok -Status` · `doctor.ps1`

Doctor shows proxy status, session hooks validity, cwd git-hook profiles, and **latest gate report** verdict.

### Offline smoke / CI

```powershell
& .\assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1 -WithHooksInstall
# optional: -WithUninstallDryRun
```

GitHub Actions: `.github/workflows/vibe-stack-smoke.yml` (Windows, parse + profiles + temp hooks; **no AI spend**).

## Layout

```text
~/.grok/
  bin/                 grok + start-grok, rtk, vibe-review, …
  rules/ skills/ hooks/   stack-owned names only under these
  token-saving/        Headroom venv, start-grok (max profile), run-rtk-enforce, doctor
  vibe-tools/          scanners, grok-ai-review, git hooks installer
    reports/           gate MD/HTML/JSON (latest.md pointer)
    cache/             diff-hash pass cache
  config.toml          managed max-savings block
  vibe-stack-manifest.json
```

`assets/hooks/*.json` in this repo are **templates** (`__GROK_HOME__` placeholders). Live hooks are generated at install with absolute `-File` paths (stdin-safe for RTK).

## Safety

- Idempotent install
- Config managed block only (`# --- grok-vibe-stack managed block ---`)
- Uninstall never deletes `grok.exe` / `auth.json` / whole `~/.grok`
- User PATH: only existing dirs; never creates under Program Files
- Emergency: `git commit|push --no-verify` · shell `RTK_BYPASS=1 …`

## Repo files

| Path | Role |
|------|------|
| `Install-GrokVibeStack.ps1` | Bootstrap (max quality + max savings) |
| `Uninstall-GrokVibeStack.ps1` | Teardown |
| `assets/` | Portable scripts, rules, requirements, config snippet, hook templates |
