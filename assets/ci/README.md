# User-repo CI twin

Copy `vibe-user-repo.yml` to your project as `.github/workflows/vibe-gate.yml`.

| Lane | Where | LLM review |
|------|--------|------------|
| `git commit` / `git push` | Local hooks after `install-vibe-hooks.ps1` | **Yes** (required) |
| This workflow | GitHub Actions | **No** — scanners / project tests only |

GitHub-hosted runners usually lack `grok` and Headroom. Do not add an AI job unless the runner has the stack and `XAI_API_KEY`.

Self-hosted Windows runner with GrokVibeStack installed: the workflow calls `run-vibe-scans.ps1 -Scope Full` (still no LLM).

Skip compile/tests: `VIBE_SKIP_PROJECT_TOOLS=1` on the job env.
