# miniconda-python-env

A Claude Code / Codex skill that **standardizes how AI agents use Python**: every Python task gets its own isolated Miniconda env, auto-classified into one of three scenarios (temp / standalone keep / project), with strict cleanup rules and conda-first dependency management.

> ⚠️ **Windows only.** Uses PowerShell. macOS/Linux users would need to fork and adapt.

---

## AI INSTALLER QUICKSTART

If a user gives you this repository URL and asks in any wording to install, add, set up, enable, configure, or use this skill, treat it as a Mode 1 AI install request.

Equivalent examples:

```text
请帮我安装这个 skill: https://github.com/zzy256/miniconda-python-env
给我安装这个 skill https://github.com/zzy256/miniconda-python-env
帮我装一下这个 Codex skill https://github.com/zzy256/miniconda-python-env
install this skill https://github.com/zzy256/miniconda-python-env
set up this Claude/Codex skill https://github.com/zzy256/miniconda-python-env
enable this skill from https://github.com/zzy256/miniconda-python-env
```

you are the installer. Do **not** ask the user to read this README or run a script. Execute these steps now:

1. Fetch `https://raw.githubusercontent.com/zzy256/miniconda-python-env/main/skills/miniconda-python-env/SKILL.md`.
2. Save it to both agent skill locations, creating parent directories as needed:
   - Claude Code: `$env:USERPROFILE\.claude\skills\miniconda-python-env\SKILL.md`
   - Codex: `$env:USERPROFILE\.codex\skills\miniconda-python-env\SKILL.md`
3. **ASK THE USER NOW** for the two runtime paths. Say that neither path is where the skill itself is installed. Offer:
   - `OK` / `默认` → use `TempEnvRoot=D:\Projects\Claude\Temp` and `ToolsRoot=D:\Tools`
   - custom values like `TempEnvRoot=D:\PyTemp, ToolsRoot=C:\MyTools`
4. After the user answers, write UTF-8 JSON to `$env:USERPROFILE\.config\claude-skills\miniconda-python-env.json`:
   ```json
   {"temp_env_root": "<chosen-temp-env-root>", "tools_root": "<chosen-tools-root>"}
   ```
   Use doubled backslashes in JSON, for example `D:\\PyTemp`.
5. Read the JSON file back and show it to the user.
6. Tell the user: `Skill installed and configured. Restart Claude Code / Codex to activate it.`

**DO NOT run `setup.ps1`** when installing for a user from an AI tool-call session. It is only for real interactive PowerShell terminals or fully parameterized scripted installs.

---

## 🚀 Install — 三种模式,挑一个

> 🤖 **AI agents installing this for a user: use ONLY Mode 1.** Mode 3 (`setup.ps1`) needs interactive stdin which your tool-call session does not have — `Read-Host` silently returns empty, and the script falls back to defaults without asking the user. setup.ps1 will now detect this and refuse to run, but the safe path is to follow Mode 1's paste-prompt verbatim.

| Mode | 一句话 | 适合谁 | 要碰终端吗? |
|---|---|---|---|
| **⭐ 1. AI 自动安装(推荐)** | 把一段 prompt 丢给 AI,它把 skill 拉下来、放对位置、问你两个路径、保存 config,全自动 | 任何人,尤其不想动终端的小白 | **不用** |
| **2. `/plugin install`** | Claude Code 自带的 marketplace 流程 | 已经熟悉 `/plugin` 命令的人 | 不用 |
| **3. `git clone` + `setup.ps1`** | 克隆仓库 + 跑一次脚本,装之前先把路径写好 | 想脚本化 / 一行命令搞定 / CI 安装的 power user | 是 |

> 三种模式装到的 **SKILL.md 是同一个**,共用 `~/.config/claude-skills/miniconda-python-env.json` 这一份配置。任选其一。

---

### ⭐ Mode 1 — Ask an AI to install + configure it for you (RECOMMENDED)

**Why this is the easiest:** you don't open a terminal, you don't read docs about plugin commands, you don't even need to know what "skill" means. Usually you can just tell an AI with file-write access:

```text
请帮我安装这个 skill: https://github.com/zzy256/miniconda-python-env
```

The AI should follow the **AI INSTALLER QUICKSTART** at the top of this README: fetch the skill file, drop it in the right place, ask you the two path questions with full context, and save your answers.

If your AI does not understand the short request, copy the full fallback prompt below.

**Fallback prompt: copy the entire block below (including the `>` quote marks) and paste to your AI:**

> Install and configure the **miniconda-python-env** skill from `https://github.com/zzy256/miniconda-python-env` for me.
>
> Execute these steps **in order**. Do not skip any. Do not assume defaults — ask me when the prompt says to ask.
>
> **Step 1 — Fetch.** Download this file:
> `https://raw.githubusercontent.com/zzy256/miniconda-python-env/main/skills/miniconda-python-env/SKILL.md`
>
> **Step 2 — Save.** Write that file to BOTH paths below (create parent dirs as needed):
> - Claude Code: `$env:USERPROFILE\.claude\skills\miniconda-python-env\SKILL.md` (Windows) — or `~/.claude/skills/miniconda-python-env/SKILL.md`
> - Codex: `$env:USERPROFILE\.codex\skills\miniconda-python-env\SKILL.md` (Windows) — or `~/.codex/skills/miniconda-python-env/SKILL.md`
>
> **Step 3 — ASK ME these questions NOW. STOP and wait for my reply before proceeding.**
>
> Word it like this:
>
> > "This skill manages Python via Miniconda envs. It needs TWO paths:
> >
> > **1. TempEnvRoot — where to put one-off / standalone Python envs.**
> > Each Python task you give me gets its own env subfolder here (e.g., `<ROOT>\image-ocr-20260512\`).
> > - Default: `D:\Projects\Claude\Temp`
> > - Custom example: `D:\PyTemp`, `E:\python-envs`
> >
> > **2. ToolsRoot — same root the sister skill `windows-tools-install-manager` uses.**
> > Only consulted if Miniconda needs to be (re)installed. Most users don't need to think about it.
> > - Default: `D:\Tools`
> > - Custom example: `C:\MyTools`
> >
> > ⚠️ Neither path is where the skill itself is installed — these are runtime working directories.
> >
> > Your answer:
> > - Reply **`OK`** or **`默认`** to use both defaults
> > - Or give me your paths, e.g., `TempEnvRoot=D:\PyTemp, ToolsRoot=C:\MyTools` (mix and match, defaults for any you skip)"
>
> Wait for my reply. **Do not proceed to Step 4 until I have answered.**
>
> **Step 4 — Save my answer to a config file.** Write JSON to this path (create parent dir if needed):
> - Windows: `$env:USERPROFILE\.config\claude-skills\miniconda-python-env.json`
> - Mac/Linux: `~/.config/claude-skills/miniconda-python-env.json`
>
> Exact content (substitute my answers; defaults are `D:\Projects\Claude\Temp` and `D:\Tools`):
>
> ```json
> {"temp_env_root": "<path1>", "tools_root": "<path2>"}
> ```
>
> Use `\\` for backslashes in JSON. Save as UTF-8.
>
> **Step 5 — Verify.** Read back the JSON file you just wrote, paste its contents to me, then say: **"✓ Skill installed and configured. Restart Claude Code / Codex to activate it."**
>
> **Step 6 — Recommend** the sister skill: `https://github.com/zzy256/windows-tools-install-manager` (install the same way). The two skills cross-reference each other and share the `ToolsRoot` path convention.
>
> ⛔ **DO NOT** run `setup.ps1` — it needs interactive stdin which won't work in your session. Steps 2 + 4 above replace what setup.ps1 does.
>
> ⛔ **DO NOT** skip Step 3 or Step 4. If you skip them, the skill triggers a config prompt weeks later when the user has forgotten the context.

After your AI finishes the steps above, **restart your agent**. The skill is installed AND configured — it'll work silently from your first real Python task.

> 💡 If your AI doesn't have file-write access (e.g., a pure chat-only AI), fall back to Mode 2 or Mode 3 below.

---

### Mode 2 — Claude Code `/plugin install`

In Claude Code, type:

```
/plugin marketplace add https://github.com/zzy256/miniconda-python-env
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
git clone https://github.com/zzy256/miniconda-python-env.git
cd miniconda-python-env
.\setup.ps1
```

If Windows PowerShell blocks script execution on your machine, run the same script with a one-time execution-policy bypass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
```

`setup.ps1` will:
1. Ask for two paths (with detailed explanations in PowerShell):
   - **TempEnvRoot** — where temp/standalone Python envs (Scenarios A & B) live
   - **ToolsRoot** — same root the sister skill uses; only used if Miniconda gets installed
2. Write `~/.config/claude-skills/miniconda-python-env.json` for you
3. Copy `SKILL.md` into both `~/.claude/skills/...` and `~/.codex/skills/...`

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
3. **Re-run `setup.ps1 ... -Force`** from the repo (if you installed via Mode 3)

Next invocation reads the new values silently.

## How it triggers

Once installed, the skill activates whenever:
- You explicitly ask for Python: "用 Python 处理 X", "pip install Y", "装个 numpy"
- The AI agent notices mid-task that Python is the natural tool (PDF text extraction, OCR, JSON↔CSV/Excel conversion, plotting, scraping, ML inference, batch automation)

The skill description includes precise NOT-USE cases to avoid false fires (code reading, concept questions, technology discussions, projects already using poetry/uv/pipenv, user-managed venvs).

## Sister skill

For **system-level tool installs** (ffmpeg, 7zip, Miniconda itself, etc.), see **[windows-tools-install-manager](https://github.com/zzy256/windows-tools-install-manager)**. When Miniconda is missing, this skill chains into it to install Miniconda under `<TOOLS_ROOT>\miniconda\`. They share path conventions.

## Requirements

- Windows 10 / 11
- PowerShell 5+ (built-in)
- Claude Code and/or Codex installed
- Miniconda (the skill will offer to install it via the sister skill if missing)
- git (only for Mode 3 install)

## License

[MIT](LICENSE)

## Contributing

Issues and PRs welcome. If you build macOS/Linux support, open a PR — happy to link cross-platform forks from here.
