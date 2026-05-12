# miniconda-python-env

A Claude Code / Codex skill that **standardizes how AI agents use Python**: every Python task gets its own isolated Miniconda env, auto-classified into one of three scenarios (temp / standalone keep / project), with strict cleanup rules and conda-first dependency management.

> ⚠️ **Windows only.** Uses PowerShell. macOS/Linux users would need to fork and adapt.

---

## 🚀 Install

> ⚠️ **DO NOT use `/plugin install` from a Claude Code marketplace** — this skill needs path configuration that the marketplace flow can't run. **`.\setup.ps1` IS the install.**

Open PowerShell and run:

```powershell
# 1. Clone the repo to anywhere
git clone https://github.com/<your-user>/miniconda-python-env.git
cd miniconda-python-env

# 2. Run the setup script (THIS is the install)
.\setup.ps1
```

`setup.ps1` will:

1. **Explain** what the skill does
2. **Ask you for TWO paths** (with detailed explanations of what each is for):
   - **TempEnvRoot** — where temp/standalone Python envs (Scenarios A & B) live (default: `D:\Projects\Claude\Temp`)
   - **ToolsRoot** — same root the sister skill uses for system tools; only used if Miniconda needs to be installed (default: `D:\Tools`)
3. **Generate** a personalized `SKILL.md` from the template with your paths baked in
4. **Copy** it into your agent's skills directory:
   - `%USERPROFILE%\.claude\skills\miniconda-python-env\SKILL.md` (Claude Code)
   - `%USERPROFILE%\.agents\skills\miniconda-python-env\SKILL.md` (Codex)

After it finishes, **restart Claude Code / Codex** and the skill is live.

### Non-interactive install

```powershell
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
```

Options:
- `-TempEnvRoot <path>` — skip the first prompt
- `-ToolsRoot <path>` — skip the second prompt
- `-Agent <claude|codex|both>` — limit which agent to install for (default: both)
- `-Force` — overwrite existing SKILL.md without confirmation

### Reconfigure later

Just re-run `setup.ps1`:

```powershell
.\setup.ps1 -TempEnvRoot "E:\NewPyHome" -Force
```

---

## What the skill does

When the user (or the AI agent, mid-task) needs Python:

1. **Detects Miniconda** — if missing, chains into the sister skill [windows-tools-install-manager](#sister-skill) to install it
2. **Classifies the task** into one of three scenarios (with a one-line reasoning shown to the user, who can override):

   | Scenario | When it applies | Env location | Cleanup |
   |---|---|---|---|
   | **A — Temp** | One-off task, no project, no reuse | `<TempEnvRoot>\<task>-<YYYYMMDD>\` | Deleted after task |
   | **B — Standalone** | User wants to keep & re-run the script later, not a project | `<TempEnvRoot>\<task>-<YYYYMMDD>\` | Kept + `environment.yml` generated |
   | **C — Project** | Python plays an ongoing role in a project (any kind: Python, frontend, backend, data, mixed-language) | `<project-root>\.conda\` | Kept inside project + `environment.yml` generated |

3. **Presents an env plan** (classification, path, name, Python version, deps, cleanup policy) and waits for explicit user confirmation
4. **Creates env** via `conda create --prefix <path> python=<v> -c conda-forge --override-channels -y` (conda-forge avoids the Anaconda ToS error introduced in 2024+)
5. **Installs deps with conda first, pip only as fallback** — better binary compatibility on Windows, faithful `environment.yml`
6. **Runs the script** via the env's Python directly (no activation needed)
7. **For Scenario A**: deletes ONLY the task's env subfolder afterward — strict scope, never widens
8. **For Scenarios B and C**: keeps the env and reports path, activation command, dep install/restore command, run command, plus generates `environment.yml`

## How it triggers

Once installed, the skill activates whenever:
- You explicitly ask for Python: "用 Python 处理 X", "pip install Y", "装个 numpy"
- The AI agent notices mid-task that Python is the natural tool (PDF text extraction, OCR, JSON↔CSV/Excel conversion, plotting, scraping, ML inference, batch automation)

The skill description includes precise NOT-USE cases to avoid false fires (code reading, concept questions, technology discussions, projects already using poetry/uv/pipenv, user-managed venvs).

## Sister skill

For **system-level tool installs** (ffmpeg, 7zip, Miniconda itself, etc.), see **[windows-tools-install-manager](https://github.com/<your-user>/windows-tools-install-manager)** — designed to work alongside this skill.

When Miniconda is missing, this skill chains into windows-tools-install-manager to install it under `<ToolsRoot>\miniconda\`. They share path conventions via the `ToolsRoot` parameter.

## Requirements

- Windows 10 / 11
- PowerShell 5+ (built-in)
- git (to clone the repo)
- Claude Code and/or Codex installed
- Miniconda — the skill will offer to install it via the sister skill if missing

## Why this skill exists

Without a convention, AI agents tend to:
- `pip install` directly into the system Python → pollution, version conflicts
- Create envs without a cleanup policy → Temp folders fill with abandoned envs
- Default to pip even when conda-forge has the package → binary compatibility issues on Windows
- Mix envs into projects randomly (some at project root, some at `~/envs`, some named)
- Hit Anaconda's new ToS error when running `conda create` without `-c conda-forge`

This skill enforces a predictable, clean Python workflow with three explicit scenarios and per-scenario rules.

## License

[MIT](LICENSE)

## Contributing

Issues and PRs welcome. If you build macOS/Linux support, open a PR with the README updated — happy to link cross-platform forks from here.
