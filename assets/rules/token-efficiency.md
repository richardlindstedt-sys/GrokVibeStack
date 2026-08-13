# Token efficiency (always on) — MAX savings profile

Save context and tokens without losing correctness.

## Stack (this machine)

- **Headroom proxy** via `start-grok` / `grok-via-headroom` (target keep-ratio **0.35**, lossless + code-aware + tool intercept + read-maturation)
- **RTK** on noisy shell — enforced by PreToolUse hook (`run-rtk-enforce.ps1`)
- **Caveman ultra** for chat output
- **Compact** at **55%** context + two-pass
- **MCP** tool output capped at **20k** bytes
- Interactive reasoning default **medium**; AI gates are **fail-closed**. Effort by profile: **standard/strict = high**, **fast = medium** (push / docs-only)
- After install/hook **file changes**: restart Grok, or once run **`/hooks` then `r`** in an already-open session. New sessions load hooks from disk automatically (not every session).
- Prefer `start-grok` (proxy up); bare `grok` with default `grok-via-headroom` fails if proxy down

## Read path

- Grep / search for symbols first; read only needed line ranges.
- Prefer Serena / ast-grep (`sg`) for symbols over dumping whole files.
- Prefer `tokei` / `scc` / `headroom loc` for repo shape over recursive `ls`.
- Prefer `difft` / `rtk git diff` over raw giant diffs.
- Prefer subagents for broad exploration; return short summaries to main thread.
- Do not re-read files already in recent context unless content may have changed.

## Shell path (RTK) — mandatory for noisy commands

Prefix with `rtk` (hook will **deny** bare noisy commands and ask you to retry):

```text
rtk git status
rtk git diff
rtk cargo test
rtk pytest
rtk npm test
rtk docker ps
rtk gh ...
rtk rg pattern
```

Bypass once only if needed: include `RTK_BYPASS` in the command string, or `rtk proxy <cmd>` for tracked raw.

## Write path (chat)

- Default caveman-ultra for chat.
- Never compress code you write into files, or error strings the user must act on.
- Avoid restating large code blocks the user already has; cite path + change.

## Quality gates (do not disable)

- On edit: fast secret/lint checks
- On commit / push: scanners + Grok AI review (profile-aware effort; do not skip)
- Never skip gates for convenience except true emergency `--no-verify`
- Full multi-reviewer panel in chat is optional — pre-commit already runs it for code

## Do not

- Invent abbreviations that hurt clarity for zero tokenizer gain.
- Over-compress multi-step destructive instructions.
- Add always-on MCP servers without need (tool defs cost tokens every turn).
- Turn on Headroom `--memory`/`--learn` or output shaper unless debugging loops is OK.
