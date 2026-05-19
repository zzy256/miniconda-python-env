# Changelog

All notable changes to `miniconda-python-env` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.3] — 2026-05-19

### Added

- Added a top-level **AI INSTALLER QUICKSTART** so users can give an AI the one-line request `请帮我安装这个 skill: https://github.com/zzy256/miniconda-python-env` and still get the full install + immediate path-configuration flow.
- Added verification coverage for the quickstart contract, including raw `SKILL.md` URL, Claude Code and Codex target paths, config JSON path, immediate user prompt, and the `setup.ps1` prohibition for AI tool-call installs.

## [1.0.2] — 2026-05-18

### Fixed

- Strengthened the `setup.ps1` non-interactive guard: redirected sessions now fail if either required path parameter is missing, preventing partial-parameter silent defaults.
- Replaced ambiguous lettered mode wording with the public Mode 1/2/3 terminology.
- Added a README fallback command for Windows PowerShell execution-policy blocks.
- Clarified Miniconda detection so global Anaconda is not silently treated as managed Miniconda.
- Documented full-path `conda.exe` use after chained Miniconda install, because PATH updates do not affect the current shell.
- Replaced the Scenario A cleanup snippet with a child-path validation guard before `Remove-Item`.
- Switched `setup.ps1` status output to ASCII to avoid mojibake in Windows PowerShell 5.

## [1.0.1] — 2026-05-18

Critical bug-fix release. v1.0.0 was unusable on Codex due to two issues:

### Fixed

- **SKILL.md YAML frontmatter `description` field now uses a folded block scalar (`>-`).** v1.0.0 had a long single-line `description:` value containing literal `:` characters (e.g., `HARD exclusion (overrides positive triggers above): do NOT use`). Strict YAML parsers (including Codex's) rejected this with `mapping values are not allowed in this context at line 2 column 519`. Claude Code's lenient parser tolerated it, which is why it slipped past pre-release testing. Folded block scalar treats the entire value as opaque text, so internal colons are safe.
- **Skill install directory for Codex corrected from `~/.agents/skills/` to `~/.codex/skills/`.** v1.0.0's README, Mode 1 prompt, and `setup.ps1` all pointed installs at the wrong path. Codex actually loads skills from `~/.codex/skills/`. All references updated.

### Notes

- If you installed v1.0.0 via Codex, your `~/.codex/skills/miniconda-python-env/SKILL.md` needs to be re-fetched from `main`. Easiest: paste the Mode 1 prompt again, or just overwrite the file from the latest raw URL.
- v1.0.0 Claude Code installs continue to work — Claude Code's parser tolerated the invalid YAML. But re-fetching the latest release is still recommended for cleanliness.

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
- Sister skill: [windows-tools-install-manager](https://github.com/zzy256/windows-tools-install-manager) for installing Miniconda itself and other system tools.
