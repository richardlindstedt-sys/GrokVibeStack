# Global Grok agent preferences

## Communication

- Default: **caveman ultra** (maximum terseness). See `~/.grok/rules/caveman.md`.
- Code, commits, PR bodies, file contents: normal professional style.
- Off: user says "normal mode" / "stop caveman" / `/caveman off`.

## Token efficiency

- Follow `~/.grok/rules/token-efficiency.md` and `~/.grok/rules/rtk.md`.
- Grep before full-file read. Subagents for broad search.
- Prefer Serena / ast-grep for symbols over dumping whole files.
- **Shell:** prefix noisy commands with `rtk` (Rust Token Killer). See `~/.grok/RTK.md`.
- Summarize noisy shell/test output; keep exact errors.
- Stack: caveman ultra (chat) + **rtk** (shell) + Headroom proxy + MCP + early two-pass compaction.
- Preferred launch: `start-grok` (auto proxy + rtk ensure; `grok-4.6` goes through Headroom). Vanilla: `-m grok-4.6-direct`.

## Skills

- `/caveman [level]` — output compression mode
- `/token-save` — refresh full stack guidance
- `/vibe-coding` — full quality workflow (scanners, profiles, hook install)

## Vibe coding (short)

- Chat: light self-check after edits. On-edit hooks handle fast secrets/linters.
- Full multi-reviewer + full scanner suite = **commit/push hooks** or explicit `vibe-review` — not every turn.
- **Gate in chat:** background commit/push. Start `monitor` on `watch-gate-now.ps1 -Monitor` when a gate starts (GATE DONE is a tick, not exit). Leftover `GATE DONE` at startup does **not** kill the watch. After a live gate, watcher lingers ~45s on that RUN's `GATE DONE`, then prints `DONE` and exits. After the last gate of the pair (commit+push, or a lone tag/push), **kill the watch**. If the next gate starts and the watch is already dead, start a new one. Poll `gate-now.txt` every ~15s (`timeout_ms`<=15000). Speak every poll: `RUN`+`NOW`+`ELAPSED` plus new `gate-status.txt` lines (scan ok/fail, reviewer votes, arbiter, fixer). Do not leave the user on the first scan line. Never wait minutes silent on bash. Stop hook blocks a silent end while the gate is live. Latch new `RUN:`; ignore stale `GATE DONE` until that RUN. A gate is done when **NOW:** has `GATE DONE` for that RUN. No popup unless `VIBE_GATE_POPUP=1`.
- Serena MCP on by default (symbol nav). Serena **remind hooks** stay off unless opted in.
- Launchers: `start-grok` · `vibe-review` · tools under `~/.grok/vibe-tools/`
