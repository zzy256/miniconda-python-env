# miniconda-python-env

A Claude Code / Codex skill that **standardizes how AI agents use Python**: every Python task gets its own isolated Miniconda env, classified into one of three scenarios (temp / standalone keep / project), with strict cleanup rules and conda-first dependency management.

> ⚠️ **Windows only.** This skill uses PowerShell commands. macOS/Linux users would need to fork and adapt.

## What it does

Whenever the user (or Claude itself, mid-task) needs Python:

1. **Detects Miniconda**; if missing, chains into the [windows-tools-install-manager](https://github.com/) sister skill to install it
2. **Classifies the task** as one of:
   - **A — Temp mid-task script**: one-off processing, no deliverable, env will be auto-deleted after the task
   - **B — Standalone keeper**: user wants to keep and re-run the script later, but it's not part of a project
   - **C — Formal project**: Python plays an ongoing role in a project (Python, frontend, backend, data, mixed-language — any project that needs Python)
3. **Presents an env plan** (path, name, Python version, dependencies, cleanup policy) and waits for explicit user confirmation
4. **Creates env** via `conda create --prefix <path> python=<v> -c conda-forge --override-channels` (conda-forge avoids the Anaconda ToS error introduced in 2024+)
5. **Installs deps with conda first, pip only as fallback** (better binary compatibility on Windows, faithful `environment.yml`)
6. **Runs the script** via the env's Python directly
7. **For Scenario A**: deletes ONLY the task's env folder afterward — strict scope, never widens
8. **For Scenarios B and C**: keeps the env and reports path/activation/run commands, plus generates `environment.yml`

## Install

### Requirements

- Windows 10/11
- PowerShell 5+ (built-in)
- Claude Code and/or Codex installed
- Miniconda (the skill will offer to install it via the sister skill if missing)

### Quick install

```powershell
# 1. Clone the repo
git clone https://github.com/<your-user>/miniconda-python-env.git
cd miniconda-python-env

# 2. Run the setup script
.\setup.ps1
```

The setup script asks you for two paths:
- **TempEnvRoot** — where Scenario A/B envs live (default: `D:\Projects\Claude\Temp`)
- **ToolsRoot** — where the sister skill installs system tools (default: `D:\Tools`); only used if Miniconda needs to be installed

It then writes the configured `SKILL.md` into:
- `%USERPROFILE%\.claude\skills\miniconda-python-env\` (Claude Code)
- `%USERPROFILE%\.agents\skills\miniconda-python-env\` (Codex)

### Non-interactive install

```powershell
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
```

Options:
- `-TempEnvRoot <path>` — your preferred Python temp env root
- `-ToolsRoot <path>` — your system-tools root (must match what windows-tools-install-manager uses)
- `-Agent <claude|codex|both>` — which agent to install for (default: both)
- `-Force` — overwrite existing SKILL.md without prompting

### Restart your agent

After install, restart Claude Code or Codex so it picks up the new skill.

## How it triggers

Once installed, the skill activates whenever:
- You explicitly ask Python things: "用 Python 处理 X", "pip install Y", "装个 numpy"
- Or Claude / Codex notices mid-task that Python is the natural tool (PDF text extraction, OCR, JSON↔CSV conversion, plotting, scraping, ML inference, batch automation)

The skill description includes precise NOT-USE cases to avoid false fires (code reading, concept questions, technology discussions, projects already using poetry/uv/pipenv, user-managed venvs).

## Three scenario classifications explained

The skill auto-classifies each Python task into one of three buckets, then handles it differently:

| Scenario | When | Env location | Cleanup |
|---|---|---|---|
| **A — Temp** | One-off task, no project, no reuse | `<TempEnvRoot>\<task>-<YYYYMMDD>\` | Deleted after task |
| **B — Standalone** | User wants to keep & re-run the script | `<TempEnvRoot>\<task>-<YYYYMMDD>\` | Kept + `environment.yml` |
| **C — Project** | Python plays an ongoing role in a project | `<project-root>\.conda\` | Kept inside project + `environment.yml` |

The classification is shown in the plan; user can override.

## Reconfigure

To change paths later:

```powershell
.\setup.ps1 -TempEnvRoot "E:\NewPyHome" -Force
```

This regenerates `SKILL.md` with the new path. Takes effect after restarting your agent.

## Sister skill

For **system-level tool installs** (ffmpeg, 7zip, Miniconda itself, etc.), see [windows-tools-install-manager](https://github.com/) — designed to work together with this skill.

When Miniconda is missing, this skill chains into windows-tools-install-manager to install it under `<ToolsRoot>\miniconda\`. They share path conventions through the `-ToolsRoot` parameter.

## Why this skill exists

Without a convention, AI agents tend to:
- `pip install` directly into the system Python (pollution, version conflicts)
- Create envs without a cleanup policy (Temp folders fill up with abandoned envs)
- Default to pip even when conda-forge has the package (binary compatibility issues on Windows)
- Mix envs into projects randomly (some at project root, some at `~/envs`, some named)
- Hit Anaconda's new ToS error when running `conda create` without specifying conda-forge

This skill enforces a predictable, clean Python workflow with three concrete scenarios and explicit rules per scenario.

## License

MIT (see [LICENSE](LICENSE))

## Contributing

Issues and PRs welcome. If you want macOS/Linux support, fork and adapt — happy to link cross-platform forks from this README.
