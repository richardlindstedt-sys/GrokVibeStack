# RTK shell compression (always on)

Prefix noisy shell commands with `rtk` so output is compacted before it hits context.

- Good: `rtk git status`, `rtk git diff`, `rtk cargo test`, `rtk pytest`, `rtk npm test`, `rtk docker ps`, `rtk gh ...`, `rtk ls`, `rtk grep`
- Chains: prefix **each** segment (`&&` `||` `;` newline, bare `&`). Residual: `|` pipes, `2>&1`/`&>`, leading `&` call op, backticks/heredocs.
- Skip for tiny commands or when full raw output required
- Debug full output: bare command, or `rtk proxy <cmd>`
- Prefer dedicated tools (`grep`, `read_file`) over shell when available; if shell needed for those jobs, still prefer `rtk ...`
- Details: `~/.grok/RTK.md`
