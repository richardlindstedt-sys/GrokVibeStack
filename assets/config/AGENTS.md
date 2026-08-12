# Global Grok agent preferences

## Communication

- Default: **caveman ultra** (maximum terseness). See `~/.grok/rules/caveman.md`.
- Code, commits, PR bodies, file contents: normal professional style.
- Off: user says "normal mode" / "stop caveman" / `/caveman off`.

## Token efficiency

- Follow `~/.grok/rules/token-efficiency.md` and `~/.grok/rules/rtk.md`.
- Grep before full-file read. Subagents for broad search.
- **Shell:** prefix noisy commands with `rtk` (Rust Token Killer). See `~/.grok/RTK.md`.
- Summarize noisy shell/test output; keep exact errors.
- Stack: caveman ultra (chat) + **rtk** (shell) + Headroom proxy (lossless + code-aware + intercept) + MCP + early two-pass compaction.
- Preferred launch: `start-grok` (auto proxy + rtk ensure + `grok-via-headroom`).

## Skills

- `/caveman [level]` — output compression mode
- `/token-save` — refresh full stack guidance

## Vibe Coding (Quality + Self-Review)

This machine is configured for high-quality "vibe coding".

Core rules:
- Use subagents aggressively and by default:
  - explore for discovery
  - plan for architecture / approach
  - implementer for writing code
  - reviewer + security-auditor for every non-trivial change
- After you generate or modify code, you MUST:
  1. Run the relevant static scanners (trivy, gitleaks, jscpd, biome/ruff/semgrep, etc.)
  2. Perform a full self-review of your own output using the reviewer subagent (or the grok-ai-review.ps1 helper).
  3. Explicitly look for duplication, dead code, unwired/incomplete features, security issues, and bugs.
- Never present code as "done" until the reviewer subagent (or equivalent review) has been run and issues addressed.
- On every commit attempt (via installed pre-commit hooks), scans + AI review will execute automatically.

Preferred launchers:
- start-grok   (full token + vibe stack)

Tools live under ~/.grok/vibe-tools/
Run full review anytime:  vibe-review   or   & "$env:USERPROFILE\.grok\vibe-tools\vibe-review.ps1"
