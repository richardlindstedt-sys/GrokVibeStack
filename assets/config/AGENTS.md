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
- **Gate in chat:** background commit/push. Start `monitor` on `watch-gate-now.ps1 -Monitor` when a gate starts (only wake). Keep it through the commit+push pair. Speak: scan result, vote, arbiter, fixer file, GATE DONE, and PROGRESS (one line: phase + elapsed). Never "still waiting" or "no new votes". Recap votes+arbiter+DONE before next git. AWC ships this commit. **next** must be fixed in the next commit (`gate-open-advisories.json`, not auto-fixed, not droppable). **later** is ledger-only (doctor lists; no auto-fail). Latch new `RUN:`. Kill watch after last gate of the pair. Stop does not nag on wait ticks. No popup unless `VIBE_GATE_POPUP=1`.
- Serena MCP on by default (symbol nav). Serena **remind hooks** stay off unless opted in.
- Launchers: `start-grok` · `vibe-review` · tools under `~/.grok/vibe-tools/`
