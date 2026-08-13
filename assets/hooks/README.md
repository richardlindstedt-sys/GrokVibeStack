# Grok session hooks (templates)

These JSON files are **valid structural templates** for review/docs.

**Do not copy them literally onto a machine.**  
`Install-GrokVibeStack.ps1` → `Install-HooksJson` writes real hooks to
`~/.grok/hooks/` with absolute `-File` paths so PreToolUse **stdin** reaches
RTK enforce / post-shell (required for deny decisions).

| Placeholder | Meaning |
|-------------|---------|
| `__GROK_HOME__` | e.g. `C:\Users\<you>\.grok` |
| `__USERPROFILE__` | e.g. `C:\Users\<you>` |

| File | Role |
|------|------|
| `token-saving.json` | SessionStart + **RTK PreToolUse deny** + shell post metrics |
| `vibe-coding.json` | On-edit checks + Stop reminder |
| `serena-hooks.json` | **Not installed by default.** Serena MCP still works. Opt-in remind hooks: `Enable-SerenaRemindHooks.ps1` (uses fail-soft wrapper). |

After install or hook **file** changes in an already-open Grok session: run **`/hooks` then `r`**, or restart Grok. New sessions load hooks from disk automatically.
Hooks do not apply to the already-running session until reloaded.
