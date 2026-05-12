# Changelog

All notable changes to `miniconda-python-env` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-12

Initial public release.

### Added

- Skill: **`miniconda-python-env`** — standardizes Python execution via Miniconda envs on Windows
- **Three install modes** for end users:
  - ⭐ Mode 1: AI-driven install (paste a prompt to an AI; recommended for non-technical users)
  - Mode 2: `/plugin install` from Claude Code marketplace
  - Mode 3: `git clone` + `setup.ps1` (power user / scripted install)
- **Self-configuring `SKILL.md`** via "Step 0 — Path Configuration":
  - Reads `~/.config/claude-skills/miniconda-python-env.json` silently on every invocation
  - On first run, asks the user once for two paths (TempEnvRoot + ToolsRoot)
  - Disambiguation warning that the paths are NOT where the skill itself lives
- **Three-scenario task classification (A / B / C)**:
  - A — Temp mid-task script: env auto-deleted after task
  - B — Standalone keeper script: env retained + `environment.yml` generated
  - C — Formal / long-lived project: env lives at `<project-root>\.conda\` + `environment.yml`
- **Conda-first dependency installs** with explicit `-c conda-forge --override-channels` (avoids Anaconda's ToS error introduced in 2024+); pip only as fallback
- **Strict cleanup scope** for Scenario A: deletes ONLY this task's env folder; never widens to siblings or parents
- **`setup.ps1`** for pre-configuration: writes the config file + copies SKILL.md to agent skills dirs (Claude Code + Codex)
- Cross-agent support: `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json` with Codex `interface` metadata
- Cross-skill integration: chains into the sister skill `windows-tools-install-manager` if Miniconda is missing
- Strict NOT-USE clauses in the skill description for code reading, concept questions, technology comparisons, Python version lookups, projects with established non-conda toolchains, user-managed activated venvs, and env uninstall operations

### Notes

- Windows-only by design. macOS/Linux users would need to fork and adapt the PowerShell snippets.
- Sister skill: [windows-tools-install-manager](https://github.com/zzy/windows-tools-install-manager) for installing Miniconda itself and other system tools.
