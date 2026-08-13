# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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
