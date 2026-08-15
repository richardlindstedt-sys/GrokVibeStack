# RTK (Rust Token Killer) — shell output compression

Always-on for this Grok setup. Compresses noisy CLI output **before** it enters context (often 60–90% fewer tokens). Safe passthrough when no filter exists.

## Rule

When using `run_terminal_command` / shell for noisy tools, **prefix with `rtk`**:

```bash
rtk git status
rtk git diff
rtk git log -n 20
rtk cargo test
rtk pytest -q
rtk npm test
rtk pnpm install
rtk docker ps
rtk gh pr list
rtk grep pattern
rtk ls path
```

Chains: prefix **each** segment. Splitters: `&&` `||` `;` newline, and bare `&` as a statement separator.

```bash
rtk git add . && rtk git status
rtk git status
rtk git diff
```

**Not split** (one `rtk` covers the whole segment):

- `|` pipelines (`rtk git log | more`)
- redirects `2>&1`, `>&`, `&>`
- leading call operator (`& rtk git status`)

**Residual (not parsed):** backtick line-continuation, heredocs, nested/unbalanced quotes. Bypass: `RTK_BYPASS=1` or `rtk proxy <cmd>`.

## Skip rtk when

- Need full raw output for debugging
- Command is already tiny (e.g. `echo ok`, single `cd`)
- Writing/editing files (use file tools, not `rtk read` as a substitute for `read_file`)

Bypass filter but still track: `rtk proxy <cmd>`

## Meta

```bash
rtk --version
rtk gain              # savings so far
rtk gain --history
```

Binary: `~/.grok/bin/rtk.exe` (also `~/.headroom/bin/rtk.exe`). Ensured by `start-grok` / `ensure-rtk.ps1`.
