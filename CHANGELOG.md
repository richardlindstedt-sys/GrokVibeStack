# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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
