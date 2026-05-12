# miniconda-python-env

A Claude Code / Codex skill that **standardizes how AI agents use Python**: every Python task gets its own isolated Miniconda env, auto-classified into one of three scenarios (temp / standalone keep / project), with strict cleanup rules and conda-first dependency management.

> ⚠️ **Windows only.** Uses PowerShell. macOS/Linux users would need to fork and adapt.

---

## 🚀 Install — 三种模式,挑一个

| Mode | 一句话 | 适合谁 | 要碰终端吗? |
|---|---|---|---|
| **⭐ 1. AI 自动安装(推荐)** | 把一段 prompt 丢给 AI,它把 skill 拉下来、放对位置、问你两个路径、保存 config,全自动 | 任何人,尤其不想动终端的小白 | **不用** |
| **2. `/plugin install`** | Claude Code 自带的 marketplace 流程 | 已经熟悉 `/plugin` 命令的人 | 不用 |
| **3. `git clone` + `setup.ps1`** | 克隆仓库 + 跑一次脚本,装之前先把路径写好 | 想脚本化 / 一行命令搞定 / CI 安装的 power user | 是 |

> 三种模式装到的 **SKILL.md 是同一个**,共用 `~/.config/claude-skills/miniconda-python-env.json` 这一份配置。任选其一。

---

### ⭐ Mode 1 — Ask an AI to install + configure it for you (RECOMMENDED)

**Why this is the easiest:** you don't open a terminal, you don't read docs about plugin commands, you don't even need to know what "skill" means. You just paste a prompt to any AI with file-write access (Claude Code, Codex, ChatGPT with file tools, etc.) — and the AI does everything: fetches the skill file, drops it in the right place, asks you the two path questions with full context, saves your answers.

**Copy the entire block below (including the `>` quote marks) and paste to your AI:**

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
> 7. **Recommend** the sister skill `windows-tools-install-manager` for system-level tool installs: `https://github.com/zzy/windows-tools-install-manager` (install it the same way). The two skills cross-reference each other and share the `<TOOLS_ROOT>` path convention.

After your AI finishes the steps above, **restart your agent**. The skill is installed AND configured — it'll work silently from your first real Python task.

> 💡 If your AI doesn't have file-write access (e.g., a pure chat-only AI), fall back to Mode 2 or Mode 3 below.

---

### Mode 2 — Claude Code `/plugin install`

In Claude Code, type:

```
/plugin marketplace add https://github.com/zzy/miniconda-python-env
/plugin install miniconda-python-env@miniconda-python-env
```

Restart Claude Code. The next time you say something like "用 Python 处理 X" or "install pandas", the skill will:
1. Ask you ONCE for two paths (with full explanations — see Step 0 in `SKILL.md`)
2. Save your answers to `~/.config/claude-skills/miniconda-python-env.json`
3. Proceed with the task — and from then on, never ask again

> Difference vs. Mode 1: here the path-config question fires at the first real Python task. In Mode 1, the AI proactively asks you right after install. Functionally identical, just different timing.

---

### Mode 3 — `git clone` + `setup.ps1` (power user / scripted install)

Best if you want **zero prompts at first use** — e.g., setting this up via a one-line install script in your own dotfiles repo:

```powershell
git clone https://github.com/zzy/miniconda-python-env.git
cd miniconda-python-env
.\setup.ps1
```

`setup.ps1` will:
1. Ask for two paths (with detailed explanations in PowerShell):
   - **TempEnvRoot** — where temp/standalone Python envs (Scenarios A & B) live
   - **ToolsRoot** — same root the sister skill uses; only used if Miniconda gets installed
2. Write `~/.config/claude-skills/miniconda-python-env.json` for you
3. Copy `SKILL.md` into both `~/.claude/skills/...` and `~/.agents/skills/...`

After this, the skill is installed AND pre-configured — the first natural trigger reads the config silently, no prompt.

Non-interactive form (for scripts / CI):
```powershell
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
```

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
