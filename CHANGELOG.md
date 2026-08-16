# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [1.4.0] - 2026-08-16

### Changed

- Gate watcher lingers **45 seconds** after the same RUN stays `GATE DONE`, then prints `DONE` and exits (was 5 minutes). Covers immediate commit-then-push; if the next gate starts later, start a new monitor
- After the last gate of a pair the agent **kills** the watch so chat is not left on a stale `GATE DONE` tick

### Fixed

- Missing `gate-now.txt` no longer resets an idle clock already started (idle-exit still fires)

## [1.3.9] - 2026-08-16

### Fixed

- `watch-gate-now.ps1 -Monitor` prints `DONE` and exits after 5 minutes of the same RUN staying `GATE DONE` (commit-then-push still stays up; `IdleSec 0` keeps the old 2h-only deadline)

## [1.3.8] - 2026-08-16

### Fixed

- `Repair-GrokConfigFile` restores the live `config.toml` from the `relocations/` backup if the post-write re-read fails `Test-VibeToml`
- Bak is merge source only when it has the quoted `[model."grok-4.6"]` Headroom override (not a bare `8787` string or duplicate tables alone)
- Smoke covers `Repair-GrokConfigFile` quarantine/relocations IO and the restore-on-recheck throw

## [1.3.7] - 2026-08-16

### Fixed

- `config.toml` merge always keep-last after strip, so a Grok rewrite (drops managed-block comments) plus a later install/start append cannot leave duplicate tables
- Installer and `start-grok` repair write backups under `~/.grok/relocations/` (never `config.toml.vibe-bak-*` next to the live file)
- `start-grok` fail-closed if `GrokToml.ps1` is missing; if live `config.toml` lacks Headroom and `config.toml.bak` looks like the stack, merge from the bak and quarantine that sidecar only
- `start-grok` does not rewrite a valid live `config.toml` just because a leftover `config.toml.bak` exists

## [1.3.6] - 2026-08-16

### Fixed

- `watch-gate-now.ps1 -Monitor` no longer prints `DONE` and exits when `NOW` is `GATE DONE`. That killed the Grok monitor between commit and push. GATE DONE is a tick; the watcher stays up across sequential gates until the 2h deadline or kill.

## [1.3.5] - 2026-08-16

### Fixed

- `start-grok` no longer kills a freshly started Headroom proxy when the TCP owner of `:8787` is the pip-wrapper python child (or grandchild) instead of the Start-Process PID. Adopts only an own-tree listener that passes Headroom argv checks and rewrites the PID file.

## [1.3.4] - 2026-08-15

### Fixed

- Gate chat no longer stays silent for minutes: PreToolUse clamps live-gate `get_command_or_subagent_output` waits to 15s; Stop hook blocks a silent end (or keeps the turn) until `GATE DONE`; ELAPSED heartbeat rewrites `gate-now.txt` every 15s while the fixer/reviewer is blocked inside `grok.exe`; `watch-gate-now.ps1 -Monitor` prints ticks for the Grok monitor tool

## [1.3.3] - 2026-08-15

### Fixed

- Gate chat stream (already on `abf625c`; this release versions it): mutex around `gate-now.txt` writes (parent+child no longer tear timestamp lines); scan child cannot reset the parent RUN; pre-commit AI inherits the scan RUN after the scan PID exits; UserPromptSubmit injects a live `RUN`/`NOW`/`ELAPSED` snapshot so a user ping is not a black box
- Push-tip worktree and SHA hygiene (already on `ee6ef0b`; this release versions it): worktree stays beside the repo (never under `.git`); trim CR from `rev-parse` before hex checks; new-branch `rev-list` keeps hex tips only

## [1.3.2] - 2026-08-15

### Fixed

- Doctor and uninstall resolve git hooks via `git rev-parse --git-path hooks` (worktree / `core.hooksPath`)
- Pre-push scans and scan-pass cache use the push-tip tree (`-TreeIsh`), not the current checkout / `git write-tree`
- Pre-push empty review ranges are not missing stdin: block only when git sends no ref lines (`HasRefLines`); delete-only / create-ref still proceed
- New-branch AI diff is unique-vs-remotes (`rev-list --not --remotes`); no 20-commit cap; no guessed origin/HEAD/main/master
- `start-grok` / uninstall never `Stop-Process -Force` a reused PID: require Headroom argv; adopt a live TCP owner and rewrite a stale PID file; confirm TCP owner is the Start-Process PID before fingerprint
- `Start-GateRun` adopts a live `RUN:` only when PID is alive and `CWD` matches; else reset
- Staged / tip scan trees stay on the repo volume (no `D:\C:\...` markdownlint ENOENT)
- Fixer worktree failure fails the gate (no in-place yolo on the main tree)
- Gate popup uses `-File` + validated run id (no `-Command` path interpolation)
- `Import-GateStatusTail` slices from last `==== gate start` then takes 60 lines (PS 5.1 `-Skip`+`-Last` no longer drops the current run)
- Push-tip scan tree uses `git worktree add --detach` outside the git dir (trimmed SHA-1/SHA-256; no `Expand-Archive`)

## [1.3.1] - 2026-08-15

### Fixed

- Installer merge no longer leaves duplicate TOML tables when Grok has rewritten `config.toml` (it drops managed-block comments). Merge is fail-closed: validate after write, UTF-8 no BOM
- `start-grok` preflights `config.toml` and repairs a stub / duplicate-table file so Headroom `grok-4.6` comes back (plain `grok` after a rename no longer stays unwired)
- Doctor reports duplicate tables / missing Headroom override
- Config reads use UTF-8 no BOM (PS 5.1 `Get-Content` was ANSI; rewrite after merge/repair could mojibake non-ASCII)
- Installer throws on invalid merge instead of continuing
- Pre-push refuses a guessed diff when git stdin has no ref lines (empty `$ranges` is not empty stdin; delete-only / create-ref still proceed); Pester crash fails the scan gate
- Fast + extra roles run in parallel (NOW heartbeats); sensitive paths raise effort; arbiter cannot downgrade in-support data corruption

## [1.3.0] - 2026-08-15

### Added

- Gate live story in chat: agent polls `gate-now.txt` while commit/push runs. First line is `RUN:` so pollers ignore stale `GATE DONE`. Append-only `gate-status.txt` for `-Wait` (reset appends a banner, does not truncate). Reviewer votes, scan start/end, fixer recap, `GATE DONE` on pass and fail. Desktop window opt-in only (`VIBE_GATE_POPUP=1`)

## [1.2.0] - 2026-08-15

### Added

- Doctor reports live Headroom proxy cmdline + fingerprint vs this stack (P2-17)
- RTK enforce splits on newlines and bare `&` statement separators (P2-23). Residual: `|` pipelines, `2>&1`/`&>` redirects, leading `&` call operator, backticks/heredocs
- Docs: Headroom MCP is on by default; optional off via `[mcp_servers.headroom] enabled = false` (P2-24)

### Removed

- Dead installer manifest flag `maxSavingsProfile` (never read) (P2-18)

## [1.1.1] - 2026-08-14

### Fixed

- Installer: call `ensure-serena.ps1 -RepoPath` as a named parameter. Splatting `@('-RepoPath', $here)` passed two positionals and failed with `A positional parameter cannot be found that accepts argument '<repo>'`

## [1.1.0] - 2026-08-14

### Added

- On-edit findings persist and inject via `UserPromptSubmit` `additionalContext` (P2-21; PostToolUse stdout is ignored by Grok)
- AI pass-cache key includes gate schema version (P2-14); legacy entries miss
- CI twin: `vibe-stack-smoke.yml` runs smoke + known-bad evals + gitleaks; optional AI job when `XAI_API_KEY` is set
- Version tags (`v1.2.3`) use profile=strict and a single-commit tag diff (no 20-commit history brief)
- Reviewer brief: stated intent vs staged diff, blast-radius symbol hits (rg/sg)
- Known-bad evals (`run-vibe-evals.ps1`): planted secret, tag plan, schema, symbol hints
- Implementer fixer runs in an isolated git worktree (unstaged user work stays put)
- Strict profile: full-file appendix when the diff was compressed; second-round full reads (P2-22)
- Gate reports: token estimate + schema version next to wall-time (P2-25)

### Fixed

- Pre-push: pass the patch as `-DiffOverride` (named). Splatting a `string[]` git diff bound hunk lines to `ProxyPort` and skipped AI review

## [1.0.3] - 2026-08-14

### Added

- Stack version `1.0.3` (`VERSION`, installer banner + manifest `stackVersion`, doctor)
- Public polish: private vulnerability reporting, secret scanning, CONTRIBUTING, issue security link; Serena pin `1.7.0`; restage untracked fixer files (P1-B4); Full scan-cache only for whole-tree Paths (P1-B6); proxy fingerprint requires `--mode token` (P1-B9); dest SHA256 + pin allowlist
- GitHub binaries (`scc`, `tokei`): pin tag + SHA256 in `assets/requirements/github-release-pins.json`; installer downloads that release only and refuses a hash mismatch (no `/releases/latest`)
- Gate live progress: flushed stdout/stderr + `~/.grok/vibe-tools/reports/live-gate.log`; 15s heartbeats while reviewer jobs run (`Write-Host` is silent under redirected git/Grok hooks)

### Fixed

- Dependabot: bump freeze pins (`aiohttp` 3.14.3, `mcp` 1.28.1, `cryptography` 50.0.0, `GitPython` 3.1.58, `h2` 4.4.1). `ecdsa` has no patched release (Minerva); still a checkov transitive
- Installer: parenthesize `Test-Path` / `Test-CommandExists` before `-or` (PS bound `-or` as a param → `WARN ensure-rtk: parameter name 'or'`)
- Serena: empty `language_servers` made symbol tools fail (`No language servers available`). `ensure-serena.ps1` installs/verifies the binary, infers LS (PowerShell 7 for `.ps1`), repairs project.yml; installer fails closed if Serena is not runnable; config disables the MCP server when the exe is missing

### Fixed (P1-B8 / B5 / B7)

- Pre-push: null `Start-Process` / null `ExitCode` blocks the push (no silent scan skip)
- Staged scan tree: no worktree `Copy-Item` fallback — missing index blob fails the gate
- New-branch push: `rev-list --max-count=20` + parent/root patch (no `sha~20` tip-only fallback); flatten git `string[]` to one patch string (PS 5.1)

### Fixed (P1-B1…B3)

- AutoProfile keeps both rename sides (`auth/x.py` → `docs/y.md` still sensitive); staged/WT uses `--name-status`
- Quoted `diff --git "a/my file"` headers parse (push DiffOverride no longer falls through to empty paths)
- Fixer restage rejects `.`, dir paths, trailing slashes, and glob/pathspec (`* ? [ :`); `git add` uses `:(literal)`

### Fixed (P0 hotfix)

- Session Stop hook is installed from `assets/hooks/vibe-coding.json` (`run-vibe-stop-remind.ps1`). Installer no longer overwrites it with an always-on `Write-Host` nag
- Uninstall never removes User PATH entries outside `~\.grok` (old manifests recorded Git/Node/npm). Installer records stack-owned PATH dirs only
- Live hook JSON is template-substituted, not `ConvertTo-Json` hashtables (avoids PS 5.1 single-element array unwrap)

### Changed

- Override built-in `grok-4.6` to Headroom proxy via quoted `[model."grok-4.6"]` (unquoted dotted ids are ignored as nested tables); vanilla hatch `[model."grok-4.6-direct"]` (`-m` honored); AI-review proxy-down fallback requires the hatch table's official `base_url`
- Config merge always strips owned sections outside the managed block (fixes duplicate-key TOML parse failures on reinstall)

### Changed (P1 quality/token)

- Slim always-on vibe rules/AGENTS; full panel lives in skill + commit hooks
- `fast` profile AI effort **medium**; standard/strict stay **high**
- Path-aware gates (`-AutoProfile`): docs-only → fast; sensitive paths add security
- Scanners: `-Scope Auto|Staged|Full`, binary-safe staged tree (`git checkout-index`), push scan-pass cache (~2h TTL)
- Stop hook reminds only after edits this session (`run-vibe-stop-remind.ps1`); opt-in always: `VIBE_STOP_REMIND=1`
- Fixer restage: blocker paths + prior-staged dirtied paths only (no `git add -u`)
- jscpd/checkov: blocking only in JS/TS or IaC domain; otherwise advisory
- RTK noisy list: `sg`/`ast-grep`/`difft`/`tokei`/`scc`/`jq`; bare `find` tightened to `find.exe` / shell `find `

### Fixed (pre-push false block)

- `run-vibe-scans.ps1` success path now `exit 0` (advisory tools no longer poison `$LASTEXITCODE`)
- `run-vibe-pre-push.ps1` runs scans via `powershell.exe -File` so process exit is authoritative

### Fixed (P0 gate / savings integrity)

- Critical scanners (`trivy`, `gitleaks`) **required by default**; set `VIBE_REQUIRE_SCANNERS=0` to soft-warn only
- AI panel: removed vote-only unstructured APPROVE fallback; normalize `severity=blocker` → vote BLOCK; harvest panel blockers into arbiter
- Fixer restage: `git add -u` + blocker paths only (no `git add -A`)
- Headroom proxy: fingerprint expected stack flags; restart when port is up but stack mismatches
- RTK enforce: check each `&&` / `||` / `;` segment (one `rtk` no longer allows the whole chain)

## [0.1.0] - 2026-08-13

### Added

- Self-contained Windows bootstrap: `Install-GrokVibeStack.ps1` / `Uninstall-GrokVibeStack.ps1` + full `assets/` payload
- Quality gates: on-edit checks, pre-commit (`standard` profile), pre-push (`fast` profile)
- Multi-reviewer AI loop (profiles fast/standard/strict), arbiter, fix/re-review, MD/HTML reports, diff-hash pass cache
- Token stack: Headroom max-coding proxy, RTK enforce, caveman, compact/MCP caps
- `doctor.ps1`, offline `Invoke-VibeStackSmoke.ps1`, GitHub Actions smoke workflow
- Staged-tree secret scanning + heuristic backup; large-diff compress for AI gate
- checkov via vibe venv launcher; Windows jscpd concrete targets
- MIT `LICENSE`, `SECURITY.md`, expanded `README.md`

### Notes

- Requires Grok Build CLI (not shipped). Third-party tools installed at bootstrap time.
- AI commit/push gates spend tokens and wall time by design.
