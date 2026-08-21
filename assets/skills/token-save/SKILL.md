---
name: token-save
description: >
  Token-efficiency workflow for this Grok setup. Use when user asks about token savings,
  headroom, rtk, context bloat, "use less tokens", or /token-save. Guides compression
  stack: caveman output, rtk shell, lean tools, Headroom MCP/proxy, subagents.
user-invocable: true
---

# Token-save stack (this machine)

## Stack (in priority order)

1. **Chat output** - caveman ultra (`/caveman`, always-on rule).
2. **Shell output** - **rtk** (Rust Token Killer): prefix noisy commands with `rtk`.
3. **Always-on rules** - `token-efficiency.md` + `caveman.md` + `rtk.md`.
4. **Context hygiene** - grep before read; subagents for explore; no full-file dumps.
5. **MCP cap** - large MCP results truncated (`[mcp] max_output_bytes=20000`).
6. **Headroom proxy** - `grok-4.6` and `grok-gate` on `:8787` (one proxy, gates sequential). `--mode token --lossless --code-aware --target-ratio 0.35` + `--no-ccr-proactive-expansion`.
7. **Headroom MCP** - `headroom__*` tools for on-demand compress/retrieve. **Default on.** Optional off: `[mcp_servers.headroom] enabled = false` in `~/.grok/config.toml` (proxy + RTK stay on).
8. **Compaction** - **55%** auto + two-pass.

**Not default:** Headroom `--memory` / `--learn`, `HEADROOM_OUTPUT_SHAPER`, profile `agent-90`.

## Agent behavior under this skill

- Prefer `grep` / scoped `read_file` over whole-file reads.
- Shell: `rtk git status`, `rtk cargo test`, `rtk pytest`, `rtk npm test`, etc. (see `~/.grok/RTK.md`).
- For long shell output still arriving raw: summarize failures + last lines; do not paste walls into replies.
- Spawn subagents for broad codebase search; return short findings to main thread.
- If Headroom MCP tools are available and a tool result or file dump is huge, compress before reasoning on full text when the task allows.
- Keep code/commands/errors exact; compress only prose and noise.
- Chat stays caveman ultra; do not drop clarity for security / irreversible ops.
- After stack install or hook file changes in an already-open session: remind **`/hooks` then `r`** (or restart) if RTK deny is not firing. New sessions load hooks automatically.

## Launcher (preferred)

From any folder:

```powershell
start-grok                 # ensure rtk + Headroom proxy + grok -m grok-4.6
start-grok -Status
start-grok -StopProxy
start-grok -NoProxy        # caveman + rtk + MCP only (no proxy)
```

Default `grok-4.6` is overridden to the Headroom proxy on `127.0.0.1:8787`. `grok-gate` is the same proxy. Use `start-grok` (not bare `grok`) for normal sessions. Vanilla: `start-grok -m grok-4.6-direct`.

Proxy logs: `~/.grok/token-saving/logs/headroom-proxy.*`  
RTK binary: `~/.grok/bin/rtk.exe` (ensure: `token-saving/scripts/ensure-rtk.ps1`)

## Verify

- `/usage` or context stats mid-session
- `rtk --version` / `rtk gain`
- `headroom doctor` / `headroom savings` if CLI installed
- `start-grok -Status` or `$env:USERPROFILE\.grok\token-saving\scripts\doctor.ps1`
- Flag file: `$env:USERPROFILE\.grok\.caveman-active` should say `ultra` after SessionStart hook

## Off ramps

- Caveman: "normal mode" or `/caveman off`
- RTK: run bare shell command (or `rtk proxy <cmd>` for tracked raw); bypass once with `RTK_BYPASS=1`
- Proxy: `start-grok -NoProxy` or model without headroom
- Headroom MCP: default on. Optional off: `[mcp_servers.headroom] enabled = false` in `~/.grok/config.toml`. Proxy + RTK stay on.
