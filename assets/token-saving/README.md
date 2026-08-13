# Token-saving stack (Grok Build)

Installed under `~/.grok` for this machine.

## One command (recommended)

From **any folder**, in PowerShell or cmd:

```text
start-grok
```

That will:

1. Ensure **rtk** (Rust Token Killer) on PATH  
2. Ensure caveman flag + PATH for Headroom tools  
3. Start **Headroom proxy** on `127.0.0.1:8787` if not already running  
4. Launch **Grok** with model `grok-4.6` (overridden to Headroom; traffic compressed)  
5. Caveman rules + RTK rules + token hygiene + Headroom MCP still load from `~/.grok` as usual  

### Useful flags

```text
start-grok -Status          # show stack status
start-grok -ProxyOnly       # only ensure proxy is up
start-grok -StopProxy       # stop background proxy
start-grok -NoProxy         # skip proxy; caveman + rtk + MCP only
start-grok -SkipRtk         # skip ensure-rtk (not recommended)
start-grok --help           # whatever you pass after still goes to grok if not a start-grok switch
start-grok -m grok-build    # pass through to grok (skips default model inject if -m present)
start-grok -m grok-4.6-direct  # vanilla Grok 4.6, no Headroom
```

Also: `stop-grok-proxy` (same as `start-grok -StopProxy`).

Shims live on PATH via `~/.grok/bin`:

- `start-grok.cmd` / `start-grok.ps1`
- `stop-grok-proxy.cmd`
- `rtk.exe`

## Components

| Piece | Role |
|-------|------|
| start-grok | One-shot launcher (rtk + proxy + grok -m grok-4.6 via Headroom) |
| **rtk** | Compresses noisy shell output before it hits context |
| caveman skill + rules | Ultra-terse chat output |
| token-efficiency + rtk rules + token-save skill | Hygiene + stack guidance |
| AGENTS.md + RTK.md | Global agent preferences + shell prefix rules |
| hooks/token-saving.json | SessionStart + PostToolUse logging |
| Headroom CLI + venv | Compression proxy + tools |
| Headroom MCP | On-demand headroom__* tools |
| grok-4.6 Headroom override | In config.toml quoted `[model."grok-4.6"]` (`grok-via-headroom` alias; `[model."grok-4.6-direct"]` = vanilla) |

## Agent shell habit

Noisy commands get an `rtk` prefix:

```text
rtk git status
rtk cargo test
rtk pytest -q
rtk npm test
```

Unknown commands pass through unchanged. Full raw when needed: bare command or `rtk proxy <cmd>`.

## Verify

```powershell
start-grok -Status
powershell -File $env:USERPROFILE\.grok\token-saving\scripts\doctor.ps1
rtk --version
rtk gain
headroom doctor
```

Proxy logs: `~/.grok/token-saving/logs/headroom-proxy.*`

