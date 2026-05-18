---
name: miniconda-python-env
description: >-
  Use when the user wants to RUN Python code, INSTALL a third-party Python
  package, or execute a .py / .ipynb file on this machine — explicit ("用
  Python 处理", "pip install X", "装个 numpy", "跑这个 notebook", "run this
  script") OR implicit (PDF text extraction, OCR, data conversion,
  JSON↔CSV/Excel, plotting, scraping, ML training / inference, batch
  automation natural in Python). Uses Miniconda envs (temp env root
  D:\Projects\Claude\Temp\, user-configurable). HARD exclusion (overrides
  positive triggers above) — do NOT use when user has their own activated venv
  OR project uses poetry/uv/pipenv/pyenv-win/Anaconda; use THEIR env even for
  "pip install X". Also do NOT use for — code reading ("看下 main.py"); concept
  questions ("what is X", "explain Y", "学 X"); tech comparisons ("Python vs
  Rust", "conda vs pip", "Anaconda vs Miniconda"); Python version/env info
  ("python 版本怎么看"); or env cleanup/uninstall ("删 conda 环境"). If
  Miniconda missing, chain into windows-tools-install-manager.
---

# Miniconda-Managed Python Environments

## Step 0 — Path Configuration (run on EVERY invocation, before anything else)

This skill needs TWO configurable paths:

- **`<TEMP_ENV_ROOT>`** — where temp/standalone Python envs (Scenarios A and B) live
- **`<TOOLS_ROOT>`** — same root the sister skill `windows-tools-install-manager` uses; only consulted if Miniconda needs to be installed

**Config file location:** `$env:USERPROFILE\.config\claude-skills\miniconda-python-env.json`

**Procedure on every invocation:**

### Case 1 — Config file EXISTS (every invocation after the first)

Read it silently:

```powershell
$cfgPath = "$env:USERPROFILE\.config\claude-skills\miniconda-python-env.json"
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$TempEnvRoot = $cfg.temp_env_root
$ToolsRoot   = $cfg.tools_root
```

Use these for every path reference below. Do NOT mention this to the user — it's silent infrastructure.

### Case 2 — Config file MISSING (first invocation only)

Tell the user, in ONE clear message:

> 我是 **miniconda-python-env** skill,第一次启用,需要你帮我设置两个路径。
>
> ⚠️ **这两个路径 ≠ skill 自己的安装位置** —— skill 文件已经装好在 `~/.claude/skills/miniconda-python-env/` 里了,不需要你管。
>
> **这两个路径 = 以后我帮你管 Python 环境时,环境本身放在哪里。**
>
> ---
>
> **路径 1: 临时 / 独立 Python 环境的根目录(`<TEMP_ENV_ROOT>`)**
>
> 用途:每次你让我跑 Python 任务(数据处理、OCR、画图、爬虫等),我会在这个根目录下建一个 Python 环境的子文件夹,每个任务一个。例如:
>
> - 你让我"OCR 一批图片" → 我建 `<TEMP_ENV_ROOT>\image-ocr-20260512\`
> - 你让我"合并几个 CSV" → 我建 `<TEMP_ENV_ROOT>\csv-merge-20260512\`
> - 你让我"画个柱状图" → 我建 `<TEMP_ENV_ROOT>\bar-chart-20260512\`
>
> 一次性任务完了我会删掉对应子文件夹;你说"以后还要用"的会保留。
>
> 推荐默认:**`D:\Projects\Claude\Temp`**
>
> ---
>
> **路径 2: 系统工具的安装根目录(`<TOOLS_ROOT>`)**
>
> 用途:如果检测到 Miniconda 没装,我会调用姊妹 skill `windows-tools-install-manager` 帮你装,装到 `<TOOLS_ROOT>\miniconda\`。如果你已经装了 Miniconda(大部分用户),这个值实际上不会被用到,**但还是配一个以防万一**(比如以后 Miniconda 被删掉重装)。
>
> 推荐默认:**`D:\Tools`**(跟 `windows-tools-install-manager` 一致,这样两个 skill 共用一套路径规则)
>
> ---
>
> **请二选一回复:**
>
> **选项 A — 都用默认值**
> 回复 "OK" 或 "默认",我用 `D:\Projects\Claude\Temp` 和 `D:\Tools`
>
> **选项 B — 自定义其中一个或两个**
> 告诉我你想用的路径,任一种格式都行:
> - 都改:`TempEnvRoot=D:\PyEnvs, ToolsRoot=C:\MyTools`
> - 只改一个:`TempEnvRoot=D:\PyEnvs`(另一个用默认)
> - 或直接两个路径分行/分号写:`D:\PyEnvs ; D:\Tools`
>
> 路径必须是绝对 Windows 路径(`<盘符>:\...` 格式)。
>
> ---
>
> 你回答之后,我会保存到 `~/.config/claude-skills/miniconda-python-env.json`,**以后所有启用都不会再问这个问题**。

Wait for the user's reply. Parse:
- "OK" / "默认" / 空回复 → use defaults `D:\Projects\Claude\Temp` and `D:\Tools`
- Otherwise extract user's values; each that's specified must match `^[A-Za-z]:\\`. Unspecified ones fall back to defaults. Re-ask if any value is ambiguous or invalid.

Save:

```powershell
$cfgDir = "$env:USERPROFILE\.config\claude-skills"
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
$TempEnvRoot = $TempEnvRoot.TrimEnd('\','/')
$ToolsRoot   = $ToolsRoot.TrimEnd('\','/')
@{ temp_env_root = $TempEnvRoot; tools_root = $ToolsRoot } |
    ConvertTo-Json | Set-Content -Path "$cfgDir\miniconda-python-env.json" -Encoding UTF8
```

Confirm to user: "✓ 记下了:`<TEMP_ENV_ROOT>` = `<value1>`,`<TOOLS_ROOT>` = `<value2>`. 现在开始你刚才说的 Python 任务…"

Then continue with the rest of this skill.

---

## Core Rules

When Python or pip is needed on this Windows machine:

1. **Always use Miniconda** to create an isolated env — never install into system Python.
2. **Classify the task** as one of:
   - **A. Temp mid-task script** — one-off processing / conversion / analysis; not a deliverable. Env deleted after task.
   - **B. Standalone long-lived script** — user wants to keep and re-run, but not part of a formal project. Env kept.
   - **C. Formal / long-lived project** — Python is used (any role) in a project that's maintained over time. Env kept inside the project.
3. **Env path by scenario:**
   - **C**: `<project-root>\.conda\`
   - **A and B**: `<TEMP_ENV_ROOT>\<env-name>\` (Step 0 loads `<TEMP_ENV_ROOT>`)
4. **If `<TEMP_ENV_ROOT>\` does NOT exist** → stop and ask user before creating. Only create that single missing directory after confirmation; don't touch anything else.
5. **If Miniconda is NOT installed** → invoke the `windows-tools-install-manager` skill (propose `<TOOLS_ROOT>\miniconda\`) before continuing.
6. **Present the env plan and wait for explicit confirmation** before creating.
7. **Cleanup for Scenario A**: after task completion, MUST delete ONLY `<TEMP_ENV_ROOT>\<env-name>\`. Never delete the Temp root, the parent directory, or any unrelated path.
8. **Kept envs (B / C)**: at task end, report path, activation command, dependency install/restore command, run command, purpose, and whether `requirements.txt` / `environment.yml` was generated.

## When to Use

### Scenario A — User explicitly asks
- "写个 Python 脚本处理 X"
- "run this with Python"
- "pip install requests"
- "用 Python 把这些 CSV 合并一下"
- "装个 pandas"

### Scenario B — You discover mid-task that Python is needed
User's task didn't mention Python but it's the natural tool:
- "把这些 PDF 的文字提出来" → pdfplumber / pymupdf
- "把这个 JSON 转成 Excel" → pandas / openpyxl
- "画一下这组数据" → matplotlib / seaborn
- "OCR 一下这些图" → pytesseract / paddleocr
- "下载并解析这个网页表格" → requests + beautifulsoup / pandas.read_html

In this case, pause before any install, present the env plan, then proceed.

### Do NOT use when
- User is already in an active env they set up themselves — just use their env
- Project already has a non-conda Python toolchain established (`poetry.lock`, `uv.lock`, `Pipfile.lock`, `pdm.lock`) — respect existing tooling
- Pure standard-library Python with no third-party imports AND no expected reuse

## Required Steps

### 1. Detect Miniconda availability

```powershell
Get-Command conda -ErrorAction SilentlyContinue
```

- **Found** → continue with step 2
- **Not found** → invoke the `windows-tools-install-manager` skill. Propose installing Miniconda to `<TOOLS_ROOT>\miniconda\` (silent install with `/InstallationType=JustMe /AddToPath=1 /S /D=<TOOLS_ROOT>\miniconda`). After install, re-check.

### 2. Classify the scenario (A / B / C)

Apply these signals in order — first match wins:

| Signal | Classification |
|---|---|
| User explicitly named a project or asked to add Python to an existing project | **C** |
| Current working directory is inside a git repo OR contains project files (`package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Makefile`, `src/`, ...), AND the Python work will be reused | **C** (even if the project is mostly non-Python) |
| User explicitly said "keep this script", "我以后还要用", "保留一下" | **B** |
| One-off operation, no mention of reuse, no project context | **A** |
| Genuinely ambiguous | **Ask the user** — don't guess silently |

**Important on C:** The project does NOT need to be a pure Python project. A React app that needs a Python build helper, a docs project with a Python lint script, a data pipeline mixing Python and SQL — all qualify as C.

### 3. Decide env name and path

**A or B (non-project):**
- Name format: `<task-keyword>-<YYYYMMDD>`
- Examples: `pdf-ocr-20260512`, `csv-merge-20260512`, `video-to-gif-20260512`
- Path: `<TEMP_ENV_ROOT>\<env-name>\`

**C (project):**
- Default path: `<project-root>\.conda\`
- If `.conda` is already taken or the project has another convention, pick another clean path inside the project root

### 4. Check Temp root existence (A / B only)

```powershell
Test-Path $TempEnvRoot
```

- **Exists** → continue
- **Does NOT exist** → stop, tell the user:
  > `<TEMP_ENV_ROOT>` (`<value>`) 不存在,需要创建吗?(只创建这一个目录,不会动其他路径)

  Wait for confirmation. Only after "OK", create:
  ```powershell
  New-Item -ItemType Directory -Path $TempEnvRoot -Force | Out-Null
  ```

### 5. Present the env plan + wait for confirmation

```
计划创建 Python 环境:
- 类别:A 临时 / B 独立脚本 / C 正式项目  ← 我判断为 X
   理由:<one-line reasoning>
- 环境路径:<full absolute path>
- 环境名:<env-name>
- Python 版本:<version, default 3.12>
- 计划安装的依赖:<list>
- 清理策略:A → 任务完成后删除  /  B、C → 保留并生成 environment.yml
- 触发场景:Scenario A (用户主动) / Scenario B (任务中发现)

按这个走可以吗?需要改类别、路径、名字、Python 版本或依赖就直说。
```

Wait for explicit confirmation. The user can correct any field, including the A/B/C classification.

### 6. Create the env

Always use `--prefix` (path-based env), never `--name`. Always pass `-c conda-forge --override-channels` — Anaconda's default channels now require explicit ToS acceptance (as of 2024+) and will error out; conda-forge avoids this.

```powershell
conda create --prefix "<env-path>" python=<version> -c conda-forge --override-channels -y
```

### 7. Install dependencies — **conda first, pip only as fallback**

**Always try `conda install` first.** Only fall back to `pip` if the package isn't on conda-forge.

**Why:**
- conda-forge ships precompiled binaries with consistent dependency resolution — especially important on Windows for native-binary stacks (numpy/scipy/pandas/matplotlib/opencv/pytorch). pip wheels can mismatch and cause runtime crashes.
- conda tracks installed packages in the env's metadata, so `conda env export` produces a faithful `environment.yml`.
- Mixing conda and pip in one env mostly works, but every pip package is a small reproducibility hit.

```powershell
# Step A — try conda first (always with conda-forge to avoid Anaconda ToS):
conda install --prefix "<env-path>" -c conda-forge --override-channels <packages> -y

# Step B — ONLY if a package isn't on conda-forge, fall back to pip via the env's Python:
& "<env-path>\python.exe" -m pip install <packages>
```

**Common cases where pip is the right call:** in-house / private packages, very new releases that haven't reached conda-forge yet, packages with `[extras]` that conda doesn't expose.

### 8. Run the script

Use the env's interpreter directly:

```powershell
& "<env-path>\python.exe" path\to\script.py
```

### 9. Cleanup (Scenario A only)

After task completion, delete ONLY the env directory:

```powershell
Remove-Item -Recurse -Force "$TempEnvRoot\<env-name>"
```

**Strict scope — never widen:**

| Path | Action |
|---|---|
| `<TEMP_ENV_ROOT>\<env-name>\` (this task's env) | ✅ Delete |
| `<TEMP_ENV_ROOT>\` (Temp root) | ❌ Never |
| Parent of `<TEMP_ENV_ROOT>\` | ❌ Never |
| Any other env in `<TEMP_ENV_ROOT>\` (from other tasks) | ❌ Never |
| Any path outside `<TEMP_ENV_ROOT>\` | ❌ Never |

Before running the delete, double-check `<env-name>` is exactly the env you created in this task. If unsure, ask the user before deleting.

### 10. Reporting for kept envs (B and C only)

After task completion, tell the user:

```
Python 环境已创建并保留:
- 路径:<full path>
- 用途:<one-line description>
- 激活:conda activate "<env-path>"
   或不激活直接调用:& "<env-path>\python.exe" ...
- 安装新依赖(首选 conda):conda install --prefix "<env-path>" -c conda-forge --override-channels <pkg>
- 安装新依赖(conda-forge 没有时再用 pip):& "<env-path>\python.exe" -m pip install <pkg>
- 从依赖文件恢复:conda env update --prefix "<env-path>" -f environment.yml
- 运行脚本:& "<env-path>\python.exe" path\to\script.py
- 依赖说明文件:environment.yml 在 <path>
```

Always generate `environment.yml` for B and C:

```powershell
conda env export --prefix "<env-path>" --no-builds > "<manifest-path>\environment.yml"
```

- B: put it alongside the script
- C: put it at project root (or update existing one)

## Red Flags — STOP and re-check

| Rationalization | Reality |
|---|---|
| "Skip Step 0, I'll just use D:\Projects\Claude\Temp" | Always run Step 0. The user may have configured a different path. It's silent if config exists — cheap to run. |
| "用户在等,直接 `pip install` 系统 Python 算了" | Defeats the entire purpose. Always conda env, always confirm plan. |
| "只是一行 Python,不用建环境吧" | If it needs ANY third-party import → build a temp env. Stdlib-only one-liners are the only exception. |
| "项目里已经有 requirements.txt,装到全局也行" | NO — install into `<project>\.conda\` so the project stays self-contained. |
| "临时任务,环境我懒得删了" | Mandatory cleanup. Otherwise `<TEMP_ENV_ROOT>\` becomes garbage. |
| "Temp 根目录不存在,我顺手 `mkdir -p` 一下" | Stop. Ask the user first. |
| "Miniconda 没装,装个系统 Python 也行" | NO — chain into windows-tools-install-manager. |
| "项目里有 poetry.lock 但我更习惯 conda" | Respect the project's existing toolchain. |
| "我把整个 `<TEMP_ENV_ROOT>\` 都清一下,反正都是临时的" | Strict scope: only THIS task's env. |

## Common Mistakes

| Mistake | Fix |
|---|---|
| Skipping Step 0 (using hardcoded path) | Always run Step 0 first — that's how `<TEMP_ENV_ROOT>` and `<TOOLS_ROOT>` get resolved |
| Skipping the plan / confirmation step | Always present plan first, even for "tiny" scripts |
| Using `conda create -n <name>` (named env) | Use `--prefix "<path>"` so the env lives where you intend |
| Defaulting to `pip install` when conda-forge has the package | Always try `conda install -c conda-forge --override-channels` first; pip only as fallback |
| Forgetting `-c conda-forge --override-channels` on conda commands | Anaconda's defaults hit ToS errors as of 2024+ |
| Forgetting cleanup for Scenario A | Always remove the env folder after task completion |
| Deleting more than this task's env folder | Strict scope: only `<TEMP_ENV_ROOT>\<env-name>\` |
| Forgetting `environment.yml` for kept envs | Always `conda env export` for B and C at task end |
| Auto-creating `<TEMP_ENV_ROOT>\` without asking | Always confirm before creating that root |
| Putting C-scenario env outside the project root | C envs MUST live inside the project (default `.conda\`) |
| Misclassifying a real project as "temp" | When in doubt about A/B/C, ASK — don't silently guess |

## Standard Workflow Examples

### Example 1: Scenario A (one-off OCR)

User: "帮我把这堆截图里的文字提出来"

1. Step 0 → silently load `<TEMP_ENV_ROOT>` = `D:\Projects\Claude\Temp` (or user's configured value)
2. Detect Miniconda → ✓
3. Classify → A (no project context, no reuse mentioned)
4. Env: `image-ocr-20260512` at `<TEMP_ENV_ROOT>\image-ocr-20260512\`
5. Temp root exists? Yes
6. Plan to user → user OK
7. Create env, conda install pillow + pytesseract (from conda-forge), run OCR
8. Show extracted text
9. Delete `<TEMP_ENV_ROOT>\image-ocr-20260512\`

### Example 2: Scenario C (Python tool in a React project)

User: "在这个 React 项目里加个数据预处理脚本,构建时跑"

1. Step 0 → silently load config
2. Detect Miniconda → ✓
3. Classify → C (in a project repo, script reused on every build)
4. Env: `<project-root>\.conda\`, Python 3.12
5. Plan to user → user OK
6. Create env, install deps, write script
7. `conda env export` → `<repo>\environment.yml`
8. Report path, activation, install / run commands

## Exclusions

- Project already uses poetry / uv / pipenv / pdm → respect the existing toolchain
- Pure non-Python projects with zero Python touchpoints → no env needed
- Standalone stdlib-only one-liners → just run with whatever Python is available
- This skill only manages envs it itself creates

## How to Change `<TEMP_ENV_ROOT>` or `<TOOLS_ROOT>` Later

The user can change the configured paths any time by:

1. **Asking you (the AI):** "把 temp env root 改成 E:\PyEnvs" → you edit `~/.config/claude-skills/miniconda-python-env.json`
2. **Editing the JSON file directly** with any text editor
3. **Re-running `setup.ps1 ... -Force`** from the plugin's git repo (if installed via Mode B)

Next invocation reads the new values silently.
