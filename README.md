# GrokVibeStack

Self-contained **Windows** installer for maximum **quality gates** + **token savings** on [Grok Build](https://x.ai).

**This repository is the full product.** Clone it, run `Install-GrokVibeStack.ps1`. All stack scripts, rules, skills, hook templates, and requirements live under `assets/`. The installer copies them onto the machine (`~\.grok\…`) and may download **third-party** tools (Python, scanners, Headroom, etc.). You do not need any other project or pack.

```text
GrokVibeStack/ (this repo)
  Install-GrokVibeStack.ps1  +  assets/**
           │
           ▼  install
  ~/.grok/  (runtime on the machine)  +  optional git hooks in projects you choose
```

| | |
|--|--|
| **License** | [MIT](./LICENSE) |
| **Security** | [SECURITY.md](./SECURITY.md) |
| **Platform** | Windows 10/11 (PowerShell 5.1+) |
| **You already need** | Grok Build CLI (`grok.exe`), authenticated |

---

## Who this is for

- You use **Grok Build on Windows** and want commit/push quality gates + aggressive token compression.
- You are fine with first install pulling scanners and Python/Node tooling (network + disk + time).
- You accept that **AI review on commit/push spends tokens and can take minutes**.

## Who this is not for (yet)

- macOS / Linux as a first-class target  
- Teams that need a zero-network / air-gapped default  
- Anyone who wants silent always-approve tool use (this stack does **not** enable that)  
- A substitute for a human security audit  

---

## Requirements

| Need | Notes |
|------|--------|
| Windows 10/11 | Primary supported OS |
| Grok Build CLI | Installed and logged in; this repo does **not** ship `grok.exe` |
| Network | winget / npm / pip / optional Serena on first install; AI gates need model access |
| Headroom proxy | Default model is `grok-via-headroom` on `127.0.0.1:8787` via `start-grok` |
| Admin (sometimes) | winget package installs may prompt; user-scope PATH preferred |

---

## Five-minute quickstart

```powershell
# 1) Clone
git clone https://github.com/richardlindstedt-sys/GrokVibeStack.git
cd GrokVibeStack

# 2) Install (run from repo root — needs assets/ next to the script)
Set-ExecutionPolicy -Scope Process Bypass
.\Install-GrokVibeStack.ps1

# 3) New terminal (PATH refresh), start proxy + Grok
start-grok -Status
start-grok

# 4) In the Grok TUI — required once per session after install/hook changes:
#    /hooks
#    then press  r
```

Optional health check:

```powershell
& "$env:USERPROFILE\.grok\token-saving\scripts\doctor.ps1"
```

Offline smoke (no AI spend):

```powershell
& .\assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1 -WithHooksInstall
```

---

## Design goals

| Goal | How |
|------|-----|
| **Quality** | On-edit checks · static scanners · multi-reviewer panel + arbiter + fix/re-review (fail-closed) |
| **Token savings** | Headroom max-coding profile · RTK auto-enforce · caveman · early compact · MCP caps |
| **Fresh machines** | One installer applies full gates + max-savings defaults |

---

## What gets installed

### Quality gates

| Gate | Trigger | Action | Blocks? |
|------|---------|--------|---------|
| On-edit | Grok file write/edit | Secrets + linters on touched file | No (report) |
| **pre-commit** | `git commit` | Scanners + **profile=standard** loop on staged diff | **Yes** |
| **pre-push** | `git push` | Scanners + **profile=fast** on push range | **Yes** |
| Stop reminder | Turn end | Remind if review skipped | No |

If you run the installer inside a git repo, that repo gets hooks automatically (unless `-SkipRepoHooks`).

**Other local git projects on the same machine** are not other “products” — they simply need hooks once each:

```powershell
& "$env:USERPROFILE\.grok\vibe-tools\scripts\install-vibe-hooks.ps1" path\to\your\project
```

### Multi-reviewer quality loop

```text
scans → reviewer panel (by profile) → arbiter → blockers? implementer fix → re-review
      → APPROVE* passes · BLOCK after max rounds fails closed
      → reports: ~/.grok/vibe-tools/reports/
      → diff-hash pass cache (same diff+profile+model can skip AI)
```

| Profile | Roles | Rounds | Fix | Typical use |
|---------|-------|--------|-----|-------------|
| **fast** | correctness | 1 | off | pre-push |
| **standard** | correctness + security + simplicity | 2 | on | pre-commit, `vibe-review` |
| **strict** | same as standard | 3 | on | high-risk / release |

```powershell
vibe-review
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile fast
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile strict
$env:VIBE_GATE_PROFILE = 'strict'
$env:VIBE_GATE_NO_CACHE = '1'
```

- **Fail-closed:** missing grok/proxy, unparseable panel/arbiter, leftover blockers → block commit/push  
- **Advisories** do not block; **blockers** do  
- Reports: `~\.grok\vibe-tools\reports\latest.md`  
- Scanners in gates are **read-only** (Biome does not auto-write)  
- **Serena MCP** installs by default; **Serena remind hooks stay off** (they broke Read UX). Opt-in: `Enable-SerenaRemindHooks.ps1`  

### Token savings (max profile)

| Layer | Setting |
|-------|---------|
| Headroom proxy | token mode, lossless, code-aware, intercept tool results, target-ratio **0.35**, read-maturation |
| RTK | Deny bare noisy shell; prefix with `rtk …` |
| Caveman | `ultra` chat style |
| Compact | **55%** + two-pass |
| MCP | `max_output_bytes = 20000` |
| Day-to-day effort | medium; **gates force high** |

### Tools pulled at install (third-party)

winget/npm/pip/uv may install: Python, Git, Node, uv, ripgrep, fd, bat, trivy, gitleaks, biome, shellcheck, hadolint, gh, jq, jscpd, markdownlint-cli, prettier, eslint, typescript, headroom-ai, ast-grep, ruff, mypy, bandit, semgrep, checkov, yamllint, vulture, rtk, Serena, PSScriptAnalyzer, Pester, and related helpers.

Those projects keep their own licenses and update cadence. Optional: `-UseFrozenReqs` for pip freeze files under `assets/requirements/`.

---

## Install options

```powershell
cd path\to\GrokVibeStack
Set-ExecutionPolicy -Scope Process Bypass
.\Install-GrokVibeStack.ps1
```

| Flag | Effect |
|------|--------|
| `-DryRun` | Plan only |
| `-SkipWinget` | Skip optional scanner CLIs (still tries Python/Git/Node/uv unless those Skip* flags are set) |
| `-SkipNpm` | Skip npm globals |
| `-SkipSerena` | Skip Serena MCP |
| `-SkipRepoHooks` | Do not install git hooks in the current directory |
| `-SkipPythonInstall` / `-SkipGitInstall` / `-SkipNodeInstall` | Skip that prereq auto-install |
| `-UseFrozenReqs` | Prefer pip freeze pins |

### After install (do not skip)

1. Open a **new** terminal (PATH).  
2. `start-grok` (starts Headroom; default model needs it).  
3. In Grok: **`/hooks` then `r`** (or restart the session).  

Permissions: this stack does **not** set `always-approve`. If tools auto-run, check Grok `/settings`. `doctor.ps1` warns when that mode is present.

---

## Uninstall (safe teardown)

```powershell
cd path\to\GrokVibeStack
.\Uninstall-GrokVibeStack.ps1 -DryRun
.\Uninstall-GrokVibeStack.ps1
# or: .\Uninstall-GrokVibeStack.ps1 -Force
```

**Keeps:** Grok Build (`grok.exe`), `auth.json`, sessions, and your projects.

**Removes (stack-owned only):** `~\.grok\token-saving\`, `~\.grok\vibe-tools\`, named hooks/rules/skills this stack wrote, PATH entries recorded in `vibe-stack-manifest.json`. Does not wipe all of `~\.grok` or strip `~\.grok\bin` while Grok lives there.

Optional aggressive flags (read script help first): `-RemoveWingetPackages`, `-RemoveNpmPackages`, `-RemoveSerena`, `-RemovePython` (only if the stack installed them).

---

## Day-to-day commands

```powershell
start-grok                          # proxy + Grok
start-grok -Status
doctor                              # or full path under token-saving\scripts\doctor.ps1
vibe-review                         # full scans + standard AI gate on current diff
& ...\scripts\run-vibe-scans.ps1    # scanners only
```

Doctor shows: Headroom proxy up/down, session hook JSON validity, gate profiles, cwd git-hook profile hints, latest gate report.

Emergency:

```text
git commit --no-verify
git push --no-verify
RTK_BYPASS=1 <command>
```

---

## Layout after install

```text
~/.grok/
  bin/                      start-grok, vibe-review, shims, …
  rules/ skills/ hooks/     stack-owned names
  token-saving/             Headroom, RTK enforce, doctor, start-grok
  vibe-tools/               scanners, grok-ai-review, hook installer
    reports/                latest.md / .html / .json
    cache/                  gate pass cache
  config.toml               managed block
  vibe-stack-manifest.json  uninstall inventory
```

**This repository:**

```text
GrokVibeStack/
  Install-GrokVibeStack.ps1
  Uninstall-GrokVibeStack.ps1
  LICENSE
  SECURITY.md
  README.md
  assets/                   all portable scripts, rules, skills, reqs, hook templates
  .github/workflows/        offline smoke CI
```

`assets/hooks/*.json` are templates (`__GROK_HOME__`). Live hooks are generated at install with absolute paths.

---

## Expected savings vs cost

| Layer | Typical effect |
|-------|----------------|
| Headroom @ 0.35 + coding profile | Often large savings on long / log-heavy sessions |
| RTK (enforced) | Cuts noisy command stdout when you use `rtk` |
| Caveman + medium effort | Fewer day-to-day output tokens |
| Compact @ 55% | Fewer giant multi-hour contexts |
| Commit/push AI gates | **Spend** tokens and wall time on purpose |

Live checks: `headroom savings` · `rtk gain` · `start-grok -Status` · `doctor.ps1`

---

## CI / smoke

```powershell
& .\assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1 -WithHooksInstall
```

GitHub Actions: `.github/workflows/vibe-stack-smoke.yml` (Windows, parse + profiles + temp hooks; **no AI spend**).

---

## Safety summary

- Idempotent install  
- Config edits limited to the managed block  
- Uninstall never deletes Grok auth or the entire `~\.grok` tree  
- PATH: only existing dirs; no Program Files creation  
- See [SECURITY.md](./SECURITY.md) for reporting and trust boundaries  

---

## License

[MIT](./LICENSE) — free to use, modify, and redistribute with attribution.

Third-party tools installed by the bootstrap retain **their** licenses.
