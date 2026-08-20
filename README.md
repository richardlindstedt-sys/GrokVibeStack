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
| **Version** | **1.5.1** ([changelog](./CHANGELOG.md); source: [`VERSION`](./VERSION)) |
| **License** | [MIT](./LICENSE) |
| **Security** | [SECURITY.md](./SECURITY.md) |
| **Contributing** | [CONTRIBUTING.md](./CONTRIBUTING.md) |
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
- A substitute for a human security audit  

---

## Requirements

| Need | Notes |
|------|--------|
| Windows 10/11 | Primary supported OS |
| Grok Build CLI | Installed and logged in; this repo does **not** ship `grok.exe` |
| Network | winget / npm / pip / optional Serena on first install; AI gates need model access |
| Headroom proxy | Built-in `grok-4.6` is overridden to `127.0.0.1:8787` via `start-grok`; keeper auto-restarts if it dies; vanilla is `grok-4.6-direct` |
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

# 4) Only if Grok was ALREADY open during install: reload hooks once
#    In TUI:  /hooks  then press  r
#    Or just restart Grok. New sessions load hooks from disk automatically.
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

## Runtime layers

How the pieces talk after install:

```text
┌─────────────────────────────────────────────────────────────┐
│  YOU  (editor / Grok chat / git CLI)                        │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
        Grok session                    git commit / push
                │                             │
                ▼                             ▼
┌──────────────────────────┐    ┌─────────────────────────────┐
│  Session hooks           │    │  Repo git hooks             │
│  on-edit → light scans   │    │  pre-commit = standard AI   │
│  stop → remind if edited │    │  pre-push   = fast AI       │
│  PreToolUse → RTK enforce│    └──────────────┬──────────────┘
└──────────┬───────────────┘                   │
           │                                   ▼
           │                    ┌──────────────────────────────┐
           │                    │  run-vibe-scans.ps1          │
           │                    │  Scope Auto|Staged|Full      │
           │                    │  + scan-pass cache (Full)    │
           │                    └──────────────┬───────────────┘
           │                                   │
           │                                   ▼
           │                    ┌──────────────────────────────┐
           └───────────────────►│  grok-ai-review.ps1          │
                                │  AutoProfile · panel · fixer │
                                │  restage · reports           │
                                └──────────────┬───────────────┘
                                               │
                    ┌──────────────────────────┼──────────────────┐
                    ▼                          ▼                  ▼
             static scanners            Headroom proxy      ~/.grok reports
             (local CLIs)               → model API         + caches
```

Two lanes, one install: **quality** (on-edit → pre-commit → pre-push) and **tokens** (slim rules, RTK, Headroom, caveman, compact).

---

## What gets installed

### Quality gates

| Gate | Trigger | Action | Blocks? |
|------|---------|--------|---------|
| On-edit | Grok file write/edit | Secrets + linters; findings saved for next prompt | No |
| Prompt inject | Next user prompt | Pending on-edit findings as additionalContext | No |
| **pre-commit** | `git commit` | Scanners + **profile=standard** loop on staged diff | **Yes** |
| **pre-push** | `git push` | Scanners + **fast** (version tags → **strict**, single-commit) | **Yes** |
| Stop / gate-live | Turn end | Block silent end while `gate-now` is live; remind if edited | Keeps turn |
| Poll clamp | `get_command_or_subagent_output` | Live gate: rewrite `timeout_ms` to 15000 | Rewrite |

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
      → diff-hash pass cache (same diff+profile+model+schema can skip AI)
```

| Profile | Roles | Rounds | Fix | Effort | Typical use |
|---------|-------|--------|-----|--------|-------------|
| **fast** | correctness (+ security if sensitive paths) | 1 | off | medium | pre-push, docs-only commit |
| **standard** | correctness + security + simplicity | 2 | on | high | pre-commit, `vibe-review` |
| **strict** | same as standard | 3 | on | high | high-risk / **version-tag push** / `vibe-review -Profile strict` |

Hooks use `-AutoProfile` (docs-only → fast; sensitive paths keep/add security). Scans: staged-first on commit (`-Scope Auto`); full on push with short scan-pass cache.

```powershell
vibe-review
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile fast
& "$env:USERPROFILE\.grok\vibe-tools\scripts\grok-ai-review.ps1" -Profile strict
$env:VIBE_GATE_PROFILE = 'strict'
$env:VIBE_GATE_NO_CACHE = '1'
$env:VIBE_REQUIRE_SCANNERS = '0'   # default is require trivy+gitleaks; 0 = soft-warn only
```

- **Fail-closed:** missing grok/proxy, unparseable panel/arbiter, leftover blockers → block commit/push  
- **Critical scanners** (`trivy`, `gitleaks`) required by default; `VIBE_REQUIRE_SCANNERS=0` soft-warns only  
- **Buckets:** `blocker` fails this SHA; `next` ships then must be fixed in the next commit; `later` is ledger-only (doctor lists, cap 40, no auto-fail). Panel `severity=blocker` forces BLOCK even if vote disagrees.  
- Reports: `~\.grok\vibe-tools\reports\latest.md` (wall-time + token estimate + schema)  
- Scanners in gates are **read-only** (Biome does not auto-write)  
- **Serena MCP** installs by default (`ensure-serena.ps1`: PyPI `serena-agent`, verify `--version`, infer/repair `.serena/project.yml` language servers — empty list breaks symbol tools). **Remind hooks stay off**. Opt-in: `Enable-SerenaRemindHooks.ps1`  

### Token savings (max profile) — knobs and what they mean

Configured defaults (not a promise of one fixed % on your whole bill):

| Layer | Configured value | What that means in practice |
|-------|------------------|-----------------------------|
| **Headroom proxy** | keep-ratio **target 0.35** (lossless + code-aware) | On traffic the proxy compresses, aim to **keep ~35%** of tokens → up to **~65% cut** on that path. Best on long sessions, big tool dumps, log/JSON-heavy turns. Does not shrink every prompt the same way. |
| **RTK** | enforce prefix on **each** noisy shell segment (`&&`/`||`/`;`/newline/bare `&`) | Often **large** stdout cuts on `git`/`test`/`docker`/`gh` when every noisy leg uses `rtk …` (see `rtk gain`). One `rtk` does not unlock the rest of a chain. Residual: `\|` pipelines, `2>&1`/`&>` redirects, leading `&` call operator, backticks/heredocs. |
| **Caveman** | chat style **ultra** | Shorter model **replies** day-to-day (output tokens), not input context. |
| **Compact** | fire at **55%** context, two-pass | Compacts earlier than a high threshold → fewer giant multi-hour contexts. |
| **MCP** | `max_output_bytes = 20000` | Caps each MCP tool payload at **20 KB** so one tool cannot flood context. |
| **Interactive effort** | default **medium** | Lower thinking cost for normal chat vs always-high. |
| **Commit/push AI gates** | forced **high** effort, multi-reviewer | These **spend** tokens on purpose for quality (not a savings feature). |

**How to measure on your machine** (after some real use):

```powershell
headroom savings    # proxy-side compression stats
rtk gain            # RTK stdout reduction stats
start-grok -Status
doctor
```

End-to-end “% off my monthly bill” depends on mix of chat vs gates vs tool noise — use the commands above rather than a single marketing number.

### Tools pulled at install (third-party)

winget/npm/pip/uv may install: Python, Git, Node, uv, ripgrep, fd, bat, trivy, gitleaks, biome, shellcheck, hadolint, gh, jq, jscpd, markdownlint-cli, prettier, eslint, typescript, headroom-ai, ast-grep, ruff, mypy, bandit, semgrep, checkov, yamllint, vulture, rtk, Serena, PSScriptAnalyzer, Pester, and related helpers.

Those projects keep their own licenses and update cadence. GitHub binaries (`scc`, `tokei`) use pinned tag + SHA256 in `assets/requirements/github-release-pins.json` (hash mismatch = skip install). Optional: `-UseFrozenReqs` for pip freeze files under `assets/requirements/`.

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

### After install

1. Open a **new** terminal (PATH refresh).  
2. `start-grok` (starts Headroom; built-in `grok-4.6` is routed through the proxy). Vanilla: `start-grok -m grok-4.6-direct`.  
3. **Grok session hooks** (`~\.grok\hooks\*.json`) load automatically on **new** Grok sessions.  
   - If Grok was **already running** while you installed or changed hooks: either restart Grok, **or** once run `/hooks` then `r` in that session.  
   - You do **not** need `/hooks` + `r` at the start of every session.

Tool auto-approve is a **Grok Build** setting (`/settings` / `permission_mode`), not controlled by this stack. Enable or disable it however you like; the installer neither turns it on nor requires it off. `doctor.ps1` only reports if it is already on.

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

Doctor shows: Headroom proxy up/down plus live cmdline + fingerprint vs this stack, session hook JSON validity, gate profiles, cwd git-hook profile hints, latest gate report.

**Watch commit/push gates in this chat.** The agent backgrounds `git commit`/`git push` and starts `watch-gate-now.ps1 -Monitor`. Chat stays quiet until something new happens (scan result, vote, arbiter, fixer file, `GATE DONE`). Waiting ticks and "no new votes" never appear. First line of `gate-now.txt` is `RUN:` — ignore leftover `GATE DONE` until that new RUN appears. After the last gate of the pair the agent kills the watch. No extra window.

```powershell
Get-Content $env:USERPROFILE\.grok\vibe-tools\reports\gate-now.txt
Get-Content $env:USERPROFILE\.grok\vibe-tools\reports\gate-status.txt -Wait   # append-only events
```

Optional desktop window: `$env:VIBE_GATE_POPUP=1`. Full log: `live-gate.log`. Report: `reports/latest.md` (overwritten each gate). Ledger: `reports/gate-open-advisories.json` — **next** must be fixed in the next commit; **later** is backlog (doctor lists).

**Headroom MCP** (`headroom__*` tools) is **on by default**. Optional off: set `enabled = false` under `[mcp_servers.headroom]` in `~/.grok/config.toml`. Proxy + RTK stay on. Re-run installer to restore the managed block, or edit that key only.

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
  config.toml               stack keys/tables merged; user /settings kept
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

## Savings vs cost (summary)

| You save on | You spend on |
|-------------|--------------|
| Compressible context via Headroom (~**0.35 keep** ⇒ up to ~**65%** off that path) | Commit/push **AI** multi-reviewer gates (high effort, by design) |
| Noisy shell stdout via **RTK** (see `rtk gain`) | First install (winget/npm/pip time + disk) |
| Shorter chat replies (caveman ultra) + medium interactive effort | |
| Earlier compact (55%) + MCP 20 KB caps | |

Measure live: `headroom savings` · `rtk gain` · `start-grok -Status` · `doctor.ps1`  
Details: [Token savings table](#token-savings-max-profile--knobs-and-what-they-mean) above.

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
