# GrokVibeStack — work queue

Goal: **minimize token costs** for vibe coders while **maximizing code quality**.

Source: final review (2026-08-13). Pick up anytime; check boxes as done.

---

## P0 — quality escapes / silent savings loss

- [x] **P0-1** Default require critical scanners (`trivy` + `gitleaks`); soft-warn only if `VIBE_REQUIRE_SCANNERS=0`
  - Files: `assets/vibe-tools/scripts/run-vibe-scans.ps1`, hooks if needed
- [x] **P0-2** Fail-closed unstructured panel fallback (no vote-only APPROVE with empty findings)
  - Files: `assets/vibe-tools/scripts/grok-ai-review.ps1` (`Invoke-ReviewerPanel`)
- [x] **P0-3** Normalize vote ↔ findings: any `severity=blocker` forces BLOCK; harvest panel blockers into arbiter path
  - Files: `grok-ai-review.ps1`
- [x] **P0-4** Fixer restage: `git add -u` + blocker paths only — never `git add -A`
  - Files: `grok-ai-review.ps1` (`Update-GitStageAfterFix`)
- [x] **P0-5** Stale Headroom proxy: fingerprint expected stack flags; restart on mismatch (not “port up = ok”)
  - Files: `assets/token-saving/scripts/start-grok.ps1`
- [x] **P0-6** RTK enforce per shell segment (`&&` / `||` / `;`) — one `rtk` must not allow the whole chain
  - Files: `assets/token-saving/scripts/run-rtk-enforce.ps1`

---

## P1 — token ↓ without gutting quality

- [ ] **P1-7** Slim always-on vibe rule: full multi-agent panel = skill/commit gate only; chat keeps light self-check
  - Files: `assets/rules/vibe-coding.md`, `assets/config/AGENTS.md`, skill
- [ ] **P1-8** `fast` profile → `reasoning-effort medium` (keep `high` for standard/strict)
  - Files: `grok-ai-review.ps1`, pre-push if needed
- [ ] **P1-9** Serena MCP default off or install `-WithSerena`
  - Files: `config-snippet.toml`, `Install-GrokVibeStack.ps1`
- [ ] **P1-10** Push security: add security reviewer **or** path-conditional when range hits auth/hooks/crypto
  - Files: `run-vibe-pre-push.ps1`, profile table
- [ ] **P1-11** Scanners staged-first on commit; push tree/hash cache TTL after clean pre-commit
  - Files: `run-vibe-scans.ps1`, `run-vibe-pre-push.ps1`
- [ ] **P1-12** Stop hook only after edit tools this session (or opt-in)
  - Files: `install-vibe-hooks.ps1`
- [ ] **P1-13** Path-aware profile: docs/md-only → fast; code/hooks → standard
  - Files: hooks + `grok-ai-review.ps1`

---

## P2 — polish

- [ ] **P2-14** Cache key += gate schema / scanner tool versions
- [ ] **P2-15** Binary-safe staged blobs (`git checkout-index` / raw blob)
- [ ] **P2-16** jscpd/checkov advisory unless diff touches those paths
- [ ] **P2-17** Doctor prints **live** proxy ratio/flags
- [ ] **P2-18** Wire or delete dead `maxSavingsProfile` flag
- [ ] **P2-19** RTK noisy list: `sg`/`ast-grep`/`difft`/`tokei`; tighten `\bfind\b`
- [ ] **P2-20** Dedupe AGENTS + rules + skills (one short canonical always-on block)
- [ ] **P2-21** On-edit: surface findings as hook `systemMessage` agent can’t ignore
- [ ] **P2-22** Large-diff second-pass targeted file read (strict only)

---

## Do not

- Drop multi-reviewer on commit to “save tokens”
- Enable Headroom memory/learn/shaper by default
- Make on-edit blocking
- Split into a second product repo

---

## Ship notes

- **v1** public: architecture OK; document AI gate cost
- **v1.1** product-complete for “max quality + min tokens”: finish **P0** then **P1-7..9** first
- Offline check: `.\assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1 -WithHooksInstall`
