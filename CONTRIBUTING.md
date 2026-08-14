# Contributing

## Issues

- Use GitHub Issues for bugs and feature requests.
- **Do not** paste API keys, `auth.json`, or exploit details. Security reports: [private advisory](https://github.com/richardlindstedt-sys/GrokVibeStack/security/advisories/new).

## Changes

This is a Windows PowerShell installer plus stack assets. Keep PRs focused.

1. Edit under `assets/` or the root install/uninstall scripts.
2. Run the offline smoke check:

   ```powershell
   .\assets\vibe-tools\scripts\Invoke-VibeStackSmoke.ps1
   ```

3. Commit from this repo so the vibe pre-commit hook runs (scans + AI review).

## Pins

GitHub binaries live in `assets/requirements/github-release-pins.json` (tag + SHA256 of the download and of the installed exe). Do not switch the installer back to `/releases/latest`.

Serena installs as `serena-agent==<version>` in `ensure-serena.ps1`. Bump that pin when you intend a new Serena release.

Winget/npm packages still track current upstream; say so in the PR if you add more.
