# Security Policy

## What this project is

**GrokVibeStack** is a self-contained install kit: this repo holds every stack
script and config template. Running the installer deploys them under `~\.grok`
on a Windows machine and may fetch third-party tools. It wraps the
**Grok Build CLI** (which you install separately).

## What the installer may touch

| Location | Purpose |
|----------|---------|
| `~\.grok\token-saving\` | Headroom venv, `start-grok`, RTK enforce hooks |
| `~\.grok\vibe-tools\` | Scanners, AI review scripts, reports, pass cache |
| `~\.grok\bin\` | Launchers (`start-grok`, `vibe-review`, shims) |
| `~\.grok\hooks\`, `rules\`, `skills\` | Stack-owned hook/rule/skill names only |
| `~\.grok\config.toml` | Managed block only (`# --- grok-vibe-stack managed block ---`) |
| `~\.grok\vibe-stack-manifest.json` | Install inventory for uninstall |
| User **PATH** | Only directories that already exist; recorded in the manifest |
| Current git repo `.git/hooks` | Optional pre-commit / pre-push (unless `-SkipRepoHooks`) |

It does **not**:

- Install or remove the Grok Build CLI itself
- Write API keys or tokens into the repo or config
- Set Grok `permission_mode = "always-approve"`
- Delete `grok.exe`, `auth.json`, or your whole `~\.grok` tree on uninstall

## Trust model

- **Pre-commit / pre-push hooks run scanners and may invoke the Grok CLI** (network + model spend) on your diffs.
- **Session hooks** can run PowerShell on tool use (e.g. RTK enforce, on-edit checks).
- Gates are **fail-closed** for critical scanner/AI failures: a broken proxy or missing verdict blocks commit/push.
- Emergency escape hatches (use sparingly):
  - `git commit --no-verify` / `git push --no-verify`
  - `RTK_BYPASS=1` on a single shell command (disables RTK deny for that invocation)

This stack **reduces risk** (secrets heuristics, scanners, multi-reviewer loop). It is **not** a formal security audit or compliance certification.

## Secrets

- Do not commit `.env`, `auth.json`, API keys, or private keys.
- Pre-commit materializes **staged** content for secret scanners (including empty-history repos) and applies a backup secret heuristic.
- If you accidentally commit a secret: rotate the credential immediately, then purge it from git history (e.g. `git filter-repo` / BFG) — force-push carefully.

## Reporting a vulnerability

If you find a security issue in **this repository’s scripts** (installer, hooks, scanners orchestration):

1. **Do not** open a public issue with exploit details if it is high severity.
2. Prefer a private report via GitHub **Security Advisories** on this repo, or contact the maintainer listed on the GitHub profile that owns the repository.
3. Include: affected script path, Windows version, Grok/stack version if known, and steps to reproduce.

We aim to acknowledge reports within a reasonable time and fix confirmed issues before any public write-up.

## Supply chain notes

The installer downloads or installs **third-party** tools (winget, npm, pip, uv, GitHub releases). Those projects carry their own licenses and security postures. Pinning is optional (`-UseFrozenReqs` for some pip sets); default prefers current packages. Review what you install on locked-down machines.

## Safe uninstall

```powershell
cd path\to\GrokVibeStack
.\Uninstall-GrokVibeStack.ps1 -DryRun   # preview
.\Uninstall-GrokVibeStack.ps1           # remove stack-owned pieces
```

Grok Build and your auth should remain. Optional flags can remove winget/npm packages the stack installed — read the script help before using them.
