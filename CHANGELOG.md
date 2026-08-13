# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- Override built-in `grok-4.6` to Headroom proxy via quoted `[model."grok-4.6"]` (unquoted dotted ids are ignored as nested tables); vanilla hatch `[model."grok-4.6-direct"]` (`-m` honored); AI-review proxy-down fallback requires the hatch table's official `base_url`
- Config merge always strips owned sections outside the managed block (fixes duplicate-key TOML parse failures on reinstall)

### Changed (P1 quality/token)

- Slim always-on vibe rules/AGENTS; full panel lives in skill + commit hooks
- `fast` profile AI effort **medium**; standard/strict stay **high**
- Path-aware gates (`-AutoProfile`): docs-only → fast; sensitive paths add security
- Scanners: `-Scope Auto|Staged|Full`, binary-safe staged tree (`git checkout-index`), push scan-pass cache (~2h TTL)
- Stop hook reminds only after edits this session (`run-vibe-stop-remind.ps1`); opt-in always: `VIBE_STOP_REMIND=1`
- Fixer restage: blocker paths + prior-staged dirtied paths only (no `git add -u`)
- jscpd/checkov: blocking only in JS/TS or IaC domain; otherwise advisory
- RTK noisy list: `sg`/`ast-grep`/`difft`/`tokei`/`scc`/`jq`; bare `find` tightened to `find.exe` / shell `find `

### Fixed (pre-push false block)

- `run-vibe-scans.ps1` success path now `exit 0` (advisory tools no longer poison `$LASTEXITCODE`)
- `run-vibe-pre-push.ps1` runs scans via `powershell.exe -File` so process exit is authoritative

### Fixed (P0 gate / savings integrity)

- Critical scanners (`trivy`, `gitleaks`) **required by default**; set `VIBE_REQUIRE_SCANNERS=0` to soft-warn only
- AI panel: removed vote-only unstructured APPROVE fallback; normalize `severity=blocker` → vote BLOCK; harvest panel blockers into arbiter
- Fixer restage: `git add -u` + blocker paths only (no `git add -A`)
- Headroom proxy: fingerprint expected stack flags; restart when port is up but stack mismatches
- RTK enforce: check each `&&` / `||` / `;` segment (one `rtk` no longer allows the whole chain)

## [0.1.0] - 2026-08-13

### Added

- Self-contained Windows bootstrap: `Install-GrokVibeStack.ps1` / `Uninstall-GrokVibeStack.ps1` + full `assets/` payload
- Quality gates: on-edit checks, pre-commit (`standard` profile), pre-push (`fast` profile)
- Multi-reviewer AI loop (profiles fast/standard/strict), arbiter, fix/re-review, MD/HTML reports, diff-hash pass cache
- Token stack: Headroom max-coding proxy, RTK enforce, caveman, compact/MCP caps
- `doctor.ps1`, offline `Invoke-VibeStackSmoke.ps1`, GitHub Actions smoke workflow
- Staged-tree secret scanning + heuristic backup; large-diff compress for AI gate
- checkov via vibe venv launcher; Windows jscpd concrete targets
- MIT `LICENSE`, `SECURITY.md`, expanded `README.md`

### Notes

- Requires Grok Build CLI (not shipped). Third-party tools installed at bootstrap time.
- AI commit/push gates spend tokens and wall time by design.
