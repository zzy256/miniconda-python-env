# miniconda-python-env

A Claude Code / Codex skill that **standardizes how AI agents use Python**: every Python task gets its own isolated Miniconda env, auto-classified into one of three scenarios (temp / standalone keep / project), with strict cleanup rules and conda-first dependency management.

> ⚠️ **Windows only.** Uses PowerShell. macOS/Linux users would need to fork and adapt.

---

## 🚀 Install — pick one of three modes

The skill is **self-configuring on first use**: whichever mode you pick, the first time the skill runs it'll ask you for two paths (or read a pre-filled config). Choose the mode that matches your style.

### Mode A — Claude Code `/plugin install` (Recommended for most users)

In Claude Code:

```
/plugin marketplace add https://github.com/zzy/miniconda-python-env
/plugin install miniconda-python-env@miniconda-python-env
```

Restart Claude Code. The next time you say something like "用 Python 处理 X" or "install pandas", the skill will:
1. Ask you ONCE for two paths (with clear explanations of what each is for)
2. Save your answers to `~/.config/claude-skills/miniconda-python-env.json`
3. Proceed with the task — and from then on, never ask again

### Mode B — Pre-configure with `setup.ps1` (Power user)

If you want to set paths BEFORE the first trigger (zero prompts at first use):

```powershell
git clone https://github.com/zzy/miniconda-python-env.git
cd miniconda-python-env
.\setup.ps1
```

`setup.ps1` will:
1. Ask you for TWO paths (with detailed explanations):
   - **TempEnvRoot** — where temp/standalone Python envs (Scenarios A & B) live
   - **ToolsRoot** — same root the sister skill uses for system tools; only used if Miniconda gets installed
2. Write `~/.config/claude-skills/miniconda-python-env.json` for you
3. Copy `SKILL.md` into both `~/.claude/skills/...` and `~/.agents/skills/...`

After this, the first trigger will silently read the config and proceed.

Non-interactive form:
```powershell
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
```

### Mode C — Ask an AI to install + configure it for you (most turnkey)

Paste this entire instruction to an AI agent (Claude Code, Codex, or any AI with file-write access):

> Please install AND configure this skill for me: `https://github.com/zzy/miniconda-python-env`
>
> Steps:
>
> 1. **Fetch** the raw content of `skills/miniconda-python-env/SKILL.md` from the repo's `main` branch (use `raw.githubusercontent.com/zzy/miniconda-python-env/main/skills/miniconda-python-env/SKILL.md`)
>
> 2. **Save** it to:
>    - `~/.claude/skills/miniconda-python-env/SKILL.md` (for Claude Code)
>    - AND/OR `~/.agents/skills/miniconda-python-env/SKILL.md` (for Codex)
>    - Create parent directories as needed
>
> 3. **Auto-configure right now** (don't wait for the first natural trigger):
>    Open the SKILL.md you just saved, find the section titled **"Step 0 — Path Configuration"**, then execute its **"Case 2 — Config file MISSING"** branch on my behalf immediately. That means:
>    - Show me the full path explanation from Step 0 (what `<TEMP_ENV_ROOT>` and `<TOOLS_ROOT>` are, where each gets used, examples, defaults)
>    - Wait for my answer (paths, or "OK" for defaults `D:\Projects\Claude\Temp` and `D:\Tools`)
>    - Validate each value looks like an absolute Windows path
>    - Save them to `~/.config/claude-skills/miniconda-python-env.json` in the exact format Step 0 specifies (`{"temp_env_root": "...", "tools_root": "..."}`)
>    - Confirm the config to me
>
> 4. **Summarize** what got installed (file paths), what was configured (both paths), and what the skill does in one short paragraph.
>
> 5. **Recommend** I restart my agent (Claude Code / Codex) so it picks up the new skill.
>
> 6. **Do NOT try to run `setup.ps1`** — it requires interactive stdin that won't work in your session. You're replacing what setup.ps1 does (writing the config + dropping SKILL.md) by doing steps 2 and 3 above.
>
> 7. **Recommend** the sister skill `windows-tools-install-manager` for system-level tool installs: `https://github.com/zzy/windows-tools-install-manager` (install it the same Mode C way). The two skills cross-reference each other and share the `<TOOLS_ROOT>` path convention.

After your AI finishes these steps, restart your agent. The skill is installed AND configured — it'll work silently from the first real use.

> 💡 **If your AI doesn't have file-write access** (e.g., a pure chat AI without tools), use Mode A or B instead.

---

## What the skill does

When the user (or the AI agent, mid-task) needs Python:

1. **Step 0 — silently load** `<TEMP_ENV_ROOT>` and `<TOOLS_ROOT>` from `~/.config/claude-skills/miniconda-python-env.json` (or asks you if config is missing — happens once, ever)
2. **Detects Miniconda** — if missing, chains into the sister skill [windows-tools-install-manager](#sister-skill) to install it
3. **Classifies the task** into one of three scenarios (with reasoning shown; user can override):

   | Scenario | When | Env location | Cleanup |
   |---|---|---|---|
   | **A — Temp** | One-off task, no project, no reuse | `<TEMP_ENV_ROOT>\<task>-<YYYYMMDD>\` | Deleted after task |
   | **B — Standalone** | Keep & re-run script, not part of a project | `<TEMP_ENV_ROOT>\<task>-<YYYYMMDD>\` | Kept + `environment.yml` |
   | **C — Project** | Python plays an ongoing role in a project | `<project-root>\.conda\` | Kept inside project + `environment.yml` |

4. **Presents an env plan** and waits for explicit user confirmation
5. **Creates env** via `conda create --prefix <path> python=<v> -c conda-forge --override-channels -y` (conda-forge avoids the Anaconda ToS error introduced in 2024+)
6. **Installs deps with conda first, pip only as fallback** — better binary compatibility on Windows, faithful `environment.yml`
7. **Runs the script** via the env's Python directly (no activation needed)
8. **For Scenario A**: deletes ONLY the task's env subfolder afterward — strict scope, never widens
9. **For Scenarios B and C**: keeps the env and reports path / activation / install / run commands, plus generates `environment.yml`

## How to change paths later

Paths are stored in `~/.config/claude-skills/miniconda-python-env.json`. Three ways to change them:

1. **Ask the AI:** "把 temp env root 改成 E:\PyEnvs" → it'll edit the JSON
2. **Edit the JSON** with any text editor
3. **Re-run `setup.ps1 ... -Force`** from the repo (if you installed via Mode B)

Next invocation reads the new values silently.

## How it triggers

Once installed, the skill activates whenever:
- You explicitly ask for Python: "用 Python 处理 X", "pip install Y", "装个 numpy"
- The AI agent notices mid-task that Python is the natural tool (PDF text extraction, OCR, JSON↔CSV/Excel conversion, plotting, scraping, ML inference, batch automation)

The skill description includes precise NOT-USE cases to avoid false fires (code reading, concept questions, technology discussions, projects already using poetry/uv/pipenv, user-managed venvs).

## Sister skill

For **system-level tool installs** (ffmpeg, 7zip, Miniconda itself, etc.), see **[windows-tools-install-manager](https://github.com/zzy/windows-tools-install-manager)**. When Miniconda is missing, this skill chains into it to install Miniconda under `<TOOLS_ROOT>\miniconda\`. They share path conventions.

## Requirements

- Windows 10 / 11
- PowerShell 5+ (built-in)
- Claude Code and/or Codex installed
- Miniconda (the skill will offer to install it via the sister skill if missing)
- git (only for Mode B install)

## License

[MIT](LICENSE)

## Contributing

Issues and PRs welcome. If you build macOS/Linux support, open a PR — happy to link cross-platform forks from here.
