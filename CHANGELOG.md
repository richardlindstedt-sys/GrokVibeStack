# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

- Shared `ListenProbe.ps1`: empty-CL `headroom.exe` is an owner only if netstat shows that PID LISTENING on the queried port. Truncated CIM cmdline (headroom, no `--port`) same rule. Full `--port N` still counts. Doctor and `start-grok` thin-wrap the helper (no third CIM copy).

## [1.5.10] - 2026-08-21

### Fixed

- Uninstall TOML fallback assigned `$raw.Split(...)` then `foreach`: a 1-line file unwraps to a string so foreach walks **characters** (same class as 1.5.9). Fallback now uses `List[string]` + Add, matching `Split-VibeTomlLines`.
- Doctor `Test-Port` only treated loopback/Any/IPv6Any as up after dropping `Get-NetTCPConnection`. A unicast bind on the same port looked **down**. Any local listener on that port counts.
- Doctor and `start-grok` `Get-ListenOwnerPids` skipped empty CIM `CommandLine`, so a live `headroom.exe` with a blank cmdline was an owner-less "up" port. Empty cmdline still counts `headroom.exe` (Name or ExecutablePath).

## [1.5.9] - 2026-08-21

### Fixed

- TOML merge parsed **zero tables**. `$Raw -split "`r?`n", -1` is not "keep trailing empties": a negative max-substrings returns the **whole file as one string** (Windows PowerShell 5.1 / some pwsh). `foreach` then walks **characters**, so `[model."grok-4.6"]` never registered. Install and `start-grok` then wrote a Headroom-less `config.toml` (marketplace/ui/privacy only). `grok models` showed stock `grok-4.6` with no Headroom alias. Split is now .NET `String.Split` + `Write-Output -NoEnumerate` so a 1-line file stays a list.

## [1.5.8] - 2026-08-21

### Fixed

- Install and `start-grok` crashed when `config.toml` was missing **or** when Grok had rewritten MCP `command` paths to `command = "C:\Users\..."` (invalid TOML escapes: `\U`, `\t`, `\.`). Python `tomllib` wrote that error to stderr; with `$ErrorActionPreference = Stop` the native ErrorRecord aborted **before** repair. `Test-TomlStrictParse` now never throws. MCP commands are written as forward-slash double-quoted paths. Merge sanitizes leftover backslash commands.
- Missing `config.toml`, a Headroom-less stub, and a grok-poisoned file all repair to a grok-parseable Headroom config. If merge still fails, install and `start-grok` write a snippet-only fallback and **still launch grok**. `start-grok` no longer refuses to start because the helper or snippet is missing.

## [1.5.7] - 2026-08-21

### Fixed

- `Test-VibeToml` still required `[model."grok-gate"]` on `:8788` after the one-proxy change. Merge of the `:8787` snippet always threw `config.toml merge still invalid`, so `start-grok` died and Grok rewrote `config.toml` down to marketplace-only. Validator now checks grok-gate **table-local** `base_url` is `:8787`. Smoke asserts the managed snippet itself passes `Test-VibeToml` and rejects a `:8788` grok-gate.
- `doctor.ps1` still used `Get-NetTCPConnection -LocalPort` and `Invoke-WebRequest /readyz` (both can hang for minutes). Listen table + CIM owners only; `/readyz` is not called.

## [1.5.6] - 2026-08-21

### Fixed

- **One Headroom proxy** (`:8787`). Dual `:8788` (`grok-gate`) fought the chat proxy and gates hatched to `grok-4.6-direct`. Gates now use `grok-4.6` sequential on `:8787`. Stream-fail retries the same Headroom. Direct hatch only if listen is dead. Installer no longer starts `:8788`.

## [1.5.5] - 2026-08-21

### Fixed

- Installer **Headroom proxy + keeper** hung forever under **pwsh**. `Start-Process -Wait` waits for the process **and its descendants**; Headroom + keeper stay alive so the step never returned after a successful start. Child wait is now `Process.WaitForExit(timeout)` on the start-grok process only (same for uninstall stop, gate preflight, and the keeper's start-grok child).
- TCP listen probe is **GetActiveTcpListeners** (local IPHlp table). No connect, so no Close hang and no leaked ESTABLISHED sockets on the keeper poll loop. `Get-CimInstance` owner lookup uses `-OperationTimeoutSec 3`.

## [1.5.4] - 2026-08-20

### Fixed

- Gate Headroom was not crashing. `/readyz` **blocks** while the proxy compresses concurrent `/v1/responses` SSE. The keeper and `start-grok -ProxyOnly` treated that as dead and **killed the live process**, which hung reviewers. Liveness is **TCP connect (400ms)** in keeper, `start-grok`, and `grok-ai-review`. `/readyz` fail on a stack-matched proxy is left alone. Gate preflight treats listen as usable. **Do not call `Get-NetTCPConnection` on the hot path** — it can block for minutes and freeze preflight. `start-grok` finds owners via CIM Headroom `--port N` (headroom/python/pythonw), not TCP-table queries. TcpClient uses abortive `Client.Close(0)` only (never `TcpClient.Close()`, which can still hang). No `EndConnect` (it hung after WaitOne). Gate preflight **never calls `/readyz`** — listen only. `start-grok` treats TCP listen as ready (does not wait on `/readyz`). HttpClient.Timeout does not abort a blocked SSE.

### Changed

- Installer starts chat Headroom `:8787` and gate Headroom `:8788` (`-NoLogonKeeper`). Next-steps document `grok-gate`. Do not restart `:8788` while a panel is streaming.

## [1.5.3] - 2026-08-20

### Added

- Dedicated Headroom for AI gates on **`:8788`** (`grok-gate`). Chat stays on **`:8787`** (`grok-4.6`). Reviews run **parallel** on the gate proxy (compressed + fast wall-clock) without starving the TUI. Hatch if `:8788` dies is still `grok-4.6-direct` (not the chat proxy). Session keeper for `:8788` only — **no logon task**. `start-grok` pid/fingerprint/keeper files are port-scoped (`headroom-proxy-8788.pid`); `:8787` keeps the legacy names.

### Fixed

- Gate preflight no longer `& start-grok` (that script's `exit 0` killed the review process). Spawns `powershell -File` and passes `-Port`.
- `start-grok -StopProxy -Port 8788` no longer kills the chat keeper. Keeper mutex/task names are per-port.

## [1.5.2] - 2026-08-20

### Fixed

- AI gates default back to Headroom (`grok-4.6` on `:8787`). 1.5.1 sent every reviewer/arbiter/fixer to `grok-4.6-direct`, so the expensive path paid full tokens. Multi-role panels run **sequential** on Headroom (one SSE) so they do not kill the chat TUI. Hatch to `grok-4.6-direct` still runs if the proxy dies mid-stream. Pass `-Model grok-4.6-direct` for the old parallel-vanilla path.

## [1.5.1] - 2026-08-20

### Fixed

- Headroom **keeper**: hidden process + logon scheduled task (`GrokVibeStack-HeadroomKeeper`) restarts the proxy within ~5s if it dies. Chat no longer stays dead after a gate SSE crash. Keeper launches `start-grok -ProxyOnly` as a **child** (dot-source/`&` hit that script's `exit 0` and killed the keeper). Abandoned mutex is taken, not treated as "already running". `-StopProxy` **disables** the logon task so reinstall pip is not locked a minute later. Custom `-Port` is passed through. Installer/uninstall also spawn `start-grok` via `powershell -File` so `exit 0` cannot abort the install runspace or skip doctor.
- Stale `OPENAI_TARGET_API_URL=https://api.x.ai/v1` (old start-grok wrote this onto the grok child) is no longer treated as an override when `XAI_API_KEY` is unset. That leftover sent every chat to api.x.ai → 401 → TUI "waiting for response"
- AI gates default to `grok-4.6-direct` so 3 parallel reviewers cannot kill the chat proxy. Hatch retry still applies if someone passes `-Model grok-via-headroom` — including the **parallel Start-Job** reviewers (was sequential/arbiter only). Hatch uses `-ProxyPort`, not hardcoded 8787
- `Convert-VibeToArray` no longer walks strings by character or hashtables by entry (would corrupt `config.toml`)
- Gate finding buckets honor JSON `bucket` then `severity`. Large-diff turn bump uses flattened patch length, not `string[]` line count
- Gate watch linger after DONE is **10 min** (commit+push reuse). **PROGRESS** every 60s (phase + elapsed) so chat is not silent unless you ask

## [1.5.0] - 2026-08-20

### Fixed

- Headroom `grok-4.6` no longer requires `XAI_API_KEY`. Session login (`auth.json`) is forwarded to `cli-chat-proxy.grok.com` like `grok-4.6-direct`. Missing env_key + `api.x.ai` was a 401; the TUI sat on "waiting for response"
- Proxy starts with `--no-http2` (Grok SSE cancel + HTTP/2 hangs) and `--no-rate-limit` (default 60rpm stalled tool-heavy turns)
- Fingerprint **v3** includes upstream host so `start-grok` restarts a stale api.x.ai proxy
- Gate reviewers retry once on `grok-4.6-direct` if Headroom dies mid-stream (`reqwest` to `:8787`). Preflight-up then crash no longer fail-closes the panel with empty votes

### Changed

- Gate findings are three buckets: **blocker** (this SHA), **next** (ledger, must fix next commit), **later** (ledger only, doctor lists, cap 40 per cwd). Legacy `advisory` maps to `next`. Schema **4**
- Reviewer prompts hunt common agent defects (fail-open, encoding, injection, unwired stubs, tests that do not assert) and vote AWC only for `next`

## [1.4.14] - 2026-08-20

### Fixed

- `config.toml` merge is key-level for tables Grok/user share (`[session]`, `[features]`, `[mcp]`, `[models]`). Only stack keys are written. User `[ui]` / `[marketplace]` / `[privacy]` and extra keys in shared tables are kept. Reinstall no longer wipes `/settings`
- Duplicate **keys** (not only duplicate table headers) fail validation: parent `[mcp_servers]` + `[mcp_servers.headroom]`, intra-table repeats, and Python `tomllib` when present. That is the parse error that made `grok.exe` refuse to start
- `Confirm-VibeConfigWrite` rewrites the known-good merge on a raced re-read. It never restores a Headroom-less stub backup (that left grok unstartable and forced deleting every `config.toml`)
- `start-grok` still auto-repairs after install on a clean home or an existing stack. Repair failure does not leave a file grok cannot parse
- Uninstall strips stack keys/tables only — not the rest of `[session]` / `[features]` / `[mcp]` / `[models]`

## [1.4.13] - 2026-08-20

### Fixed

- Headroom **0.36.0**: 0.35 returned 502 on buffered Grok `/v1/responses` SSE (TUI showed Retrying; direct model worked). Floor is `headroom-ai[proxy]>=0.36.0` with `tokenizers>=0.22.0,<=0.23.0` (0.36 refuses to start the proxy extra without them)
- Proxy fingerprint includes the Headroom version so `start-grok` restarts after a pip upgrade instead of keeping the old 0.35 process
- Dropped `--read-maturation` (beta) and `--intercept-tool-results` (canary) from the default proxy argv. Headroom 0.36 stable aborts on those flags. Also clears leftover `HEADROOM_READ_MATURATION` from the parent env
- `start-grok` waits for `/readyz` (not just TCP listen). Gate preflight falls back to `grok-4.6-direct` if the proxy is up but not ready
- `doctor` warns on Headroom < 0.36 and probes `/readyz`

## [1.4.12] - 2026-08-17

### Fixed

- Pre-push **update** ranges (`remote..local`) now flatten `git diff` through `ConvertTo-SinglePatchText`. PS 5.1 used to join every hunk line with a blank line, so the common push path sent a broken patch to the reviewer
- Null `$LASTEXITCODE` after AI review is fail-closed (was treated as pass). Empty-range / delete-ref already exit 0 before review, so they never see that mapping
- Pre-commit inherit: only a **dead** scan + `VIBE_GATE_INHERIT=1` takes `PID:`. A live sibling (overlapping `vibe-review` / hook) attaches and does not steal the owner PID
- Full scan-pass cache writes only when `-TreeIsh` is set. Worktree Full no longer hashes `write-tree`/`HEAD` and authorizes a later push skip
- Open advisories are injected into the **next reviewer brief**, not only chat. Cwd match is case-insensitive
- On-edit findings merge per path (clean edit of B does not drop A). Extra secret patterns (`github_pat_`, `sk-`/`xai-`). Serena write tools via `use_tool` / `serena__*`
- Pre-commit AI is `-StagedOnly` — no working-tree or whole-project fallback
- `install-vibe-hooks` looks at `vibe-tools/templates/vibe-coding.json` (installer copies it). If no unsubstituted template exists, a valid live hook is kept instead of failing after git hooks were already written
- `doctor` is a `~\.grok\bin` shim so the README command works after PATH refresh
- Gate schema **3** (advisory brief in reviewer context invalidates old pass-cache hits)

## [1.4.11] - 2026-08-17

### Fixed

- Installer parses again. `Get-PipLockedPaths` used `\"` inside a double-quoted regex; PowerShell treated that as a string terminator (`ParserError` at line 525)

## [1.4.10] - 2026-08-17

### Fixed

- Reinstall no longer dies on `WinError 32` when Headroom proxy/MCP still holds `headroom.exe`. Installer stops those lockers, renames only the locked entry points, force-reinstalls on retry, and restores `.old` copies if pip did not rewrite them

## [1.4.9] - 2026-08-16

### Fixed

- Open-advisory resolve rebuilds the row instead of setting `resolvedRun` on a deserialized PSCustomObject (that threw and blocked the 1.4.8 push)

## [1.4.8] - 2026-08-16

### Fixed

- Open advisories persist in `gate-open-advisories.json` and must be fixed in the next commit (inject + rule). Not auto-fixed, not dropped when `latest.md` is overwritten
- Reviewer wait no longer writes `(~Ns)` / `none finished yet` into NOW. `Set-GateWaitNow` refreshes ELAPSED only; chat stays quiet
- Shared `gate-chat-lib.ps1` (tick key, wait test, RUN parse). Stop still speaks if VOTE lines exist while NOW says waiting
- Fixer OnPulse: null Start-Process fail-closed, pulse errors logged, temp logs deleted
- Gate reports write UTF-8 BOM and replace em dashes so Windows does not show mojibake
- Wait-silence smoke waits for VOTE, then polls for a leaked wait tick (no fixed sleep)
- Open-advisory merge uses a cwd+id hashtable (no ForEach-Object `$hit`). Same-cwd ids missing from this pass are marked resolved

## [1.4.7] - 2026-08-16

### Fixed

- Gate chat stays quiet until something real happens. Monitor never prints wait (`~15s`) ticks. Stop hook no longer nags on `Waiting on …` (that was the `no new votes` spam). Prompt inject says write zero chat if nothing new

## [1.4.6] - 2026-08-16

### Fixed

- Gate chat speaks only on new events (NOW phase, vote, arbiter, fixer file, GATE DONE). Monitor no longer wakes on ELAPSED-only ticks
- Stop recap ack (`gate-last-done-ack.txt`): after chat names that RUN + GATE DONE, later turns do not re-block for 8 minutes
- Fixer loop is visible and fail-closed: live file-write pulses, copied paths listed, 0-file copy stops empty re-review rounds so the agent can commit and push

## [1.4.5] - 2026-08-16

### Fixed

- Gate recap cannot vanish on commit-then-push. `Write-GateDone` / new RUN persist `gate-last-done.txt`. UserPromptSubmit injects that prior RUN (votes + arbiter + DONE) plus the live snapshot, including `GATE DONE`. Stop hook blocks end-of-turn after a fresh DONE until chat named that RUN and `GATE DONE`

## [1.4.4] - 2026-08-16

### Changed

- Requirement floors to current PyPI latest (2026-08-16): `headroom-ai>=0.35.0`, `ast-grep-cli>=0.45.1`, `ruff>=0.16.3`, `mypy>=2.3.1`, `bandit>=1.9.4`, `semgrep>=1.173.0`, `vulture>=2.16`, `yamllint>=1.38.0`, `checkov>=3.3.11`
- Installer `pip install -U -r` so a re-run upgrades existing venvs to those floors
- Direct pins in `*-freeze.txt` match those versions (`-UseFrozenReqs`)
- GitHub binaries: `scc` still `v3.7.0` (latest with Windows zip). `tokei` still `v13.0.0-alpha.0` — `v14.0.0` ships no Windows exe
- Serena remains `1.7.0` (PyPI latest). `ensure-serena.ps1` reinstalls if the installed version does not match the pin

## [1.4.3] - 2026-08-16

### Fixed

- Gate chat shows scan/reviewer/arbiter events, not only the current `NOW` line. Watcher prints `EVT` ticks; UserPromptSubmit injects the event tail from `gate-now.txt`. `$seenEvents` clears on a new `RUN`
- Each reviewer vote is published as it finishes (`NOW` + EVT include vote and summary/reason), not batched after the whole panel
- Waiting heartbeat no longer replaces those votes with `votes in: names`. Sticky `VOTE:` lines keep verdict + reason; watcher prints `VOTE`; inject has a VOTES block
- Watcher reads the whole `gate-now.txt` snapshot (`Get-GateSnapshot`), not an 8-line header. Smoke writes a fake file with `VOTE:` + scan and asserts monitor prints both

## [1.4.2] - 2026-08-16

### Fixed

- Uninstall: if managed-block markers remain, strip that block only; if Grok dropped them, strip stack MCP/model tables (`headroom`/`serena`/`grok-4.6*`) -- never whole `[session]`/`[mcp]`/`[models]`. Pre-strip backup under `relocations/`
- Uninstall removes `checkov.cmd` (now in installer `binShims`) and the dropped `~/.grok/VERSION`

## [1.4.1] - 2026-08-16

### Fixed

- Watcher does not arm idle-exit on leftover `GATE DONE` at startup. That printed `DONE` and killed the Grok monitor before the next gate wrote a new `RUN`. Idle starts only after this process has seen a live (non-DONE) `NOW`

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
