---
name: miniconda-python-env
description: >-
  ANY Python work on Windows starts with setting up its conda env - use this
  skill FIRST, before writing/running code. It places/keeps the env by task
  type: temp one-offs (deleted) vs in-project keepers (<project>\.conda, reused).
  Triggers: running/installing Python ("用 Python 处理", "pip install X", "run
  this script"); implicit one-offs (PDF/OCR, CSV/Excel, automation); and
  ESPECIALLY developing a Python project - whether the user names a stack ("PyQt6
  桌面工具", Django/Flask/FastAPI/PyTorch) or gives only a goal and you pick
  Python (ML/DL, data, web/API, crawler, desktop/GUI). REUSE an existing env,
  never recreate. Do NOT use when a usable project env exists (activated venv,
  .venv/venv, poetry/uv/pipenv/pdm lock, or a conda/Anaconda env the project
  uses): reuse THAT even for "pip install X"; if Anaconda only global, ask
  first. Do NOT use for non-Python goals (JS/mobile/static), code reading,
  concepts, comparisons, versions, deleting envs. Missing Miniconda - chain
  into windows-tools-install-manager.
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
$TempEnvRoot = [System.IO.Path]::GetFullPath($TempEnvRoot.Trim())
$ToolsRoot   = [System.IO.Path]::GetFullPath($ToolsRoot.Trim())
if ($TempEnvRoot -notmatch '^[A-Za-z]:\\$') { $TempEnvRoot = $TempEnvRoot.TrimEnd('\','/') }
if ($ToolsRoot -notmatch '^[A-Za-z]:\\$') { $ToolsRoot = $ToolsRoot.TrimEnd('\','/') }
@{ temp_env_root = $TempEnvRoot; tools_root = $ToolsRoot } |
    ConvertTo-Json | Set-Content -Path "$cfgDir\miniconda-python-env.json" -Encoding UTF8
```

Confirm to user: "✓ 记下了:`<TEMP_ENV_ROOT>` = `<value1>`,`<TOOLS_ROOT>` = `<value2>`. 现在开始你刚才说的 Python 任务…"

Then continue with the rest of this skill.

---

## Core Rules

When Python or pip is needed on this Windows machine:

1. **Reuse before you create.** Before doing anything else, check whether a usable env already exists for this work (see Step 2.5). An env this skill already built for the project, an existing `.conda`, a `.venv`/`venv`, an interpreter the current work has been using, or a lock-file toolchain (poetry/uv/pipenv/pdm/pyenv-win) all mean **reuse that env — do not build a second one.** Creating a duplicate env mid-project is the single most common failure of this skill; it produces "why is it making a new environment?" surprises and breaks already-working code.
2. **Always use Miniconda** when you DO need a new env — never install into system Python.
3. **Engage early for projects.** For a Python project (Scenario C), the right moment to create the env is at **project start / first dependency**, not at test time. If you build the project structure first and only reach for an env when a test needs to run, you've already missed the window — and a later run/test (often in a subagent) will be tempted to "fix" the missing env by creating one. Set the env up once, up front, then reuse it for every run, test, and `pytest` for the life of the project.
4. **Classify the task** as one of:
   - **A. Temp mid-task script** — one-off processing / conversion / analysis; not a deliverable. Env deleted after task.
   - **B. Standalone long-lived script** — user wants to keep and re-run, but not part of a formal project. Env kept.
   - **C. Formal / long-lived project** — Python is used (any role) in a project that's maintained over time, including GUI/desktop apps (PyQt/PySide/Tkinter), web backends (Django/Flask/FastAPI), CLIs, and libraries. Env kept inside the project and reused across all sessions and subagents.
5. **Env path by scenario:**
   - **C**: `<project-root>\.conda\`
   - **A and B**: `<TEMP_ENV_ROOT>\<env-name>\` (Step 0 loads `<TEMP_ENV_ROOT>`)
6. **If `<TEMP_ENV_ROOT>\` does NOT exist** → stop and ask user before creating. Only create that single missing directory after confirmation; don't touch anything else.
7. **If Miniconda is NOT installed** → invoke the `windows-tools-install-manager` skill (propose `<TOOLS_ROOT>\miniconda\`) before continuing.
8. **Present the env plan and wait for explicit confirmation** before creating a NEW env. Reusing an env that already exists needs no confirmation — just use it (and say which one, in one line).
9. **Cleanup for Scenario A**: after task completion, MUST delete ONLY `<TEMP_ENV_ROOT>\<env-name>\`. Never delete the Temp root, the parent directory, or any unrelated path. Never delete a Scenario B or C env, and never delete an env you merely reused rather than created.
10. **Kept envs (B / C)**: at task end, report path, activation command, dependency install/restore command, run command, purpose, and whether `requirements.txt` / `environment.yml` was generated.

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

### Scenario C — The user states a GOAL and YOU choose Python

This is the most-missed trigger. Real requests usually name an outcome, not a stack — the user rarely says "用 PyQt 做界面 / 用 PyTorch 训个网络 / 用 Flask 写后端". They say what they want, and you pick the technology. The moment you decide the implementation will be Python, you are starting a Python project — set up the env BEFORE you scaffold or write the first file.

- "做一个能识别发票关键信息的小工具" → you choose Python + an OCR/ML stack → Scenario C
- "训练一个能区分猫狗的模型" → you choose Python + PyTorch → Scenario C
- "做个爬虫,把某网站的商品价格抓下来出个报表" → you choose Python + requests/scrapy + pandas → Scenario C
- "写个后端 API 管理我的书单" → if you choose Python (FastAPI/Flask/Django) → Scenario C; if you choose a non-Python stack, this skill does not apply

Domains where Python is the usual choice: ML/DL, data processing/analysis, scientific computing, scraping, automation/scripting, backend APIs, desktop/GUI tooling. Engage the moment Python is decided — don't wait until a test needs to run. If the goal clearly implies a non-Python stack (a mobile app, a static marketing site, a React frontend), do **not** use this skill.

### Do NOT use when (or: reuse, don't recreate)
- User is already in an active env they set up themselves — just use their env
- Project already has a non-conda Python toolchain established (`poetry.lock`, `uv.lock`, `Pipfile.lock`, `pdm.lock`) — respect existing tooling
- Project already has a usable interpreter that the work has been using — a `.venv`/`venv` directory, an existing `<project>\.conda`, a `requirements.txt` the project installs against, or simply the Python the earlier part of this session has been running. **Reuse it.** This is the case that bites multi-task projects and dispatched test subagents: the project is mid-build on one interpreter, then a "run the tests" step decides it needs a fresh Miniconda env. It does not — use the interpreter the project is already on.
- Pure standard-library Python with no third-party imports AND no expected reuse

When the project's existing interpreter is system Python or a bare venv and you think it *should* be a conda env, do not silently switch it mid-project — surface the mismatch to the user and let them decide. Migrating an in-flight project to conda is a deliberate choice, not something to do behind a "run the tests" task.

## Required Steps

### 1. Detect Miniconda availability

```powershell
$PreferredConda = Join-Path $ToolsRoot 'miniconda\Scripts\conda.exe'
$CondaExe = $null

if (Test-Path $PreferredConda) {
    $CondaExe = $PreferredConda
}
else {
    $cmd = Get-Command conda -ErrorAction SilentlyContinue
    if ($cmd) { $CondaExe = $cmd.Source }
}
```

- **Preferred Miniconda found at `<TOOLS_ROOT>\miniconda\Scripts\conda.exe`** → use that full path as `$CondaExe` for every conda command below.
- **Only another `conda` is found on PATH** → inspect it before use:
  ```powershell
  $info = & $CondaExe info --json | ConvertFrom-Json
  $root = [string]$info.root_prefix
  ```
  - If `$root` clearly points to Miniconda, continue with `$CondaExe`.
  - If `$root` points to Anaconda and this is an Anaconda-managed project, respect the project and use that env/toolchain.
  - If `$root` points to Anaconda but the user did not ask to use Anaconda, stop and ask: use existing Anaconda for this task, or install separate Miniconda under `<TOOLS_ROOT>\miniconda\`?
- **No conda found** → invoke the `windows-tools-install-manager` skill. Propose installing Miniconda to `<TOOLS_ROOT>\miniconda\` (silent install with `/InstallationType=JustMe /AddToPath=1 /S /D=<TOOLS_ROOT>\miniconda`). After install, do not rely on PATH in the current shell; set:
  ```powershell
  $CondaExe = Join-Path $ToolsRoot 'miniconda\Scripts\conda.exe'
  & $CondaExe --version
  ```
  If that full-path check fails, report the install problem instead of continuing.

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

### 2.5 Detect an existing usable env — REUSE before you create

This step is what stops the skill from building a second environment on top of one that already works. Run it before Step 3 for **every** invocation, and especially before any run/test step.

Look, in this order, for an env this work should reuse:

```powershell
# (a) An env this skill already built for this project:
Test-Path "<project-root>\.conda\python.exe"
# (b) A non-conda project venv:
Test-Path "<project-root>\.venv\Scripts\python.exe"
Test-Path "<project-root>\venv\Scripts\python.exe"
# (c) A lock-file / managed toolchain at the project root:
#     poetry.lock | uv.lock | Pipfile.lock | pdm.lock | environment.yml
```

Decision:

- **(a) `<project>\.conda` exists** → reuse it. Skip Steps 3–6 (creation and the confirmation plan). Go straight to install/run using `"<project-root>\.conda\python.exe"`. If a dependency is missing, install it INTO this env, don't make a new one.
- **(b) a `.venv`/`venv` exists, or the current session has already been running some interpreter for this project** → that is the project's environment. Use it. Do not create a conda env unless the user explicitly asks to migrate the project to conda.
- **(c) a lock-file toolchain is present** → respect it (poetry/uv/pipenv/pdm). This skill stands down; use their tooling.
- **Nothing found** → this is a genuinely new env. Continue to Step 3.

For Scenario A/B, the equivalent check is: does `<TEMP_ENV_ROOT>\<env-name>\` already exist from an earlier run of the same task? If yes and it's healthy, reuse it instead of recreating.

> The whole point: an env is created **once** and then **reused**. If you're about to run `conda create` and an interpreter for this project already exists, stop — you're about to cause the "why did it make a new environment?" problem.

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

Only when Step 2.5 found nothing to reuse. If you're reusing an existing env, skip this and just state which env you're using in one line.

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

### 6. Create the env — only if Step 2.5 found nothing to reuse

If Step 2.5 found a reusable env, you are not here — you're installing into / running against that env. Reach this step only for a genuinely new env.

Always use `--prefix` (path-based env), never `--name`. Always pass `-c conda-forge --override-channels` — Anaconda's default channels now require explicit ToS acceptance (as of 2024+) and will error out; conda-forge avoids this.

```powershell
& $CondaExe create --prefix "<env-path>" python=<version> -c conda-forge --override-channels -y
```

### 7. Install dependencies — **conda first, pip only as fallback**

**Always try `conda install` first.** Only fall back to `pip` if the package isn't on conda-forge.

**Why:**
- conda-forge ships precompiled binaries with consistent dependency resolution — especially important on Windows for native-binary stacks (numpy/scipy/pandas/matplotlib/opencv/pytorch). pip wheels can mismatch and cause runtime crashes.
- conda tracks installed packages in the env's metadata, so `conda env export` produces a faithful `environment.yml`.
- Mixing conda and pip in one env mostly works, but every pip package is a small reproducibility hit.

```powershell
# Step A — try conda first (always with conda-forge to avoid Anaconda ToS):
& $CondaExe install --prefix "<env-path>" -c conda-forge --override-channels <packages> -y

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
$envPath = Join-Path $TempEnvRoot '<env-name>'
$rootFull = [System.IO.Path]::GetFullPath($TempEnvRoot).TrimEnd('\') + '\'
$envFull = [System.IO.Path]::GetFullPath($envPath).TrimEnd('\') + '\'
$leaf = Split-Path -Leaf $envFull.TrimEnd('\')

if (-not $envFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing cleanup outside TEMP_ENV_ROOT: $envFull"
}
if ($leaf -ne '<env-name>') {
    throw "Refusing cleanup because env name check failed: $leaf"
}

Remove-Item -LiteralPath $envFull -Recurse -Force
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
- 激活:conda activate "<env-path>" (in a new shell where conda is on PATH)
   或不激活直接调用:& "<env-path>\python.exe" ...
- 安装新依赖(首选 conda):& "<conda-exe>" install --prefix "<env-path>" -c conda-forge --override-channels <pkg>
- 安装新依赖(conda-forge 没有时再用 pip):& "<env-path>\python.exe" -m pip install <pkg>
- 从依赖文件恢复:& "<conda-exe>" env update --prefix "<env-path>" -f environment.yml
- 运行脚本:& "<env-path>\python.exe" path\to\script.py
- 依赖说明文件:environment.yml 在 <path>
```

Always generate `environment.yml` for B and C:

```powershell
$yaml = & $CondaExe env export --prefix "<env-path>" --no-builds
if ($LASTEXITCODE -ne 0) { throw "conda env export failed with exit code $LASTEXITCODE" }
$yaml = $yaml | Where-Object { $_ -notmatch '^prefix:\s*' }
$yaml | Set-Content -LiteralPath "<manifest-path>\environment.yml" -Encoding UTF8
```

- B: put it alongside the script
- C: put it at project root (or update existing one)
- Remove the exported top-level `prefix:` entry so the manifest does not contain a machine-specific absolute path.
- Write explicitly as UTF-8; do not use PowerShell `>` because Windows PowerShell 5.1 writes redirected text as UTF-16LE.

## Running inside a subagent / non-interactive task

This section exists because the most damaging failure mode of this skill happens here. A main agent building a project dispatches a subagent to "run the tests." That subagent loads this skill, sees a project, classifies it **C**, and — with no memory of which interpreter the project has been using and no way to ask the user — starts creating a fresh `<project>\.conda`. The main agent then has to abort it. The fix is a clear division of labor:

**If you are the MAIN agent dispatching a subagent that will run or test Python:**

- Resolve the environment **before** you dispatch. Run Step 2.5; if the project has no env yet and one is warranted, create it now (with the user's confirmation) so it exists before any subagent needs it.
- Pass the interpreter into the subagent's task prompt explicitly, e.g.:
  > Use this exact Python interpreter for all runs and tests: `D:\Proj\myapp\.conda\python.exe`. Do NOT create, modify, or look for another environment. If it is missing or a package is absent, stop and report back — do not build an env.
- This keeps env decisions in the one place that has the user and the full context: you.

**If you ARE the subagent (you were dispatched with a specific task):**

- **Never create a new env, and never ask for confirmation** — you can't, and it's not your call. Your job is to run the task in the environment that already exists.
- Use the interpreter path you were handed. If you weren't handed one, detect the project's existing env via Step 2.5 (`<project>\.conda`, `.venv`, `venv`) and use that.
- If you find **no** usable env, do **not** create one. Stop and report back to the main agent: "No project Python env found at `<paths checked>`; need an env before I can run the tests." Let the main agent decide.

The rule of thumb: **environments are created by the main, interactive session — never spun up by a dispatched task as a side effect of running tests.**

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
| "项目已经在用某个 python,但我跑测试还是建个 conda env 干净点" | NO — run Step 2.5 and REUSE the project's existing interpreter. A new env mid-project breaks working code and surprises the user. Migrating to conda is a separate, explicit decision. |
| "我是被派来跑测试的子代理,顺手把环境建了" | Subagents never create envs. Use the interpreter you were given (or detect the existing one); if none, report back to the main agent. |
| "项目要新建了,先把代码写完,环境等跑测试再说" | Create the project env at the START. Deferring it to test time is exactly what triggers the duplicate-env failure. |

## Common Mistakes

| Mistake | Fix |
|---|---|
| Skipping Step 0 (using hardcoded path) | Always run Step 0 first — that's how `<TEMP_ENV_ROOT>` and `<TOOLS_ROOT>` get resolved |
| Skipping the plan / confirmation step when creating a NEW env | Always present plan first, even for "tiny" scripts (reuse of an existing env needs no plan) |
| Creating a new env when one already exists for the project | Run Step 2.5 first; reuse `<project>\.conda` / `.venv` / `venv` / the in-use interpreter |
| A dispatched subagent spinning up its own env to run tests | Subagents reuse the handed/detected env or report back — they never create |
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
4. Step 2.5 → no `.conda` / `.venv` yet → genuinely new
5. Env: `<project-root>\.conda\`, Python 3.12
6. Plan to user → user OK
7. Create env, install deps, write script
8. `conda env export` → `<repo>\environment.yml`
9. Report path, activation, install / run commands

### Example 3: Scenario C lifecycle (PyQt app over many tasks, with test subagents)

User: "帮我做一个 PyQt 桌面应用,功能逐步加" — a large project built task by task.

1. **At project start** (first dependency, before writing much code): Step 0 → detect Miniconda → classify **C** → Step 2.5 finds no env → present plan → create `<project>\.conda` with `python=3.12` + PyQt6 from conda-forge. This is the project's one and only env.
2. **Each feature task** that needs to run or import code uses `& "<project>\.conda\python.exe" ...`. Step 2.5 finds `.conda` and reuses it — no new env, no confirmation prompt.
3. **Dispatching a test subagent** after a task: the MAIN agent passes the interpreter in the task prompt — "run pytest with `<project>\.conda\python.exe`; do not create or look for another env." The subagent runs the tests in that env and never tries to build one. (See "Running inside a subagent".)
4. New dependency for a later feature → `conda install --prefix "<project>\.conda" -c conda-forge ...` into the SAME env; refresh `environment.yml`.

The env is born once at step 1 and reused for the entire life of the project — including every test run.

## Exclusions

- Project already uses poetry / uv / pipenv / pdm → respect the existing toolchain
- Project already has a usable interpreter (`.venv`/`venv`, an existing `.conda`, or one the session has been using) → reuse it; do not create a second env
- Pure non-Python projects with zero Python touchpoints → no env needed
- Standalone stdlib-only one-liners → just run with whatever Python is available
- This skill manages envs it itself creates, but it must still DETECT and REUSE pre-existing project envs rather than duplicating them

## How to Change `<TEMP_ENV_ROOT>` or `<TOOLS_ROOT>` Later

The user can change the configured paths any time by:

1. **Asking you (the AI):** "把 temp env root 改成 E:\PyEnvs" → you edit `~/.config/claude-skills/miniconda-python-env.json`
2. **Editing the JSON file directly** with any text editor
3. **Re-running `setup.ps1 ... -Force`** from the plugin's git repo (if installed via Mode 3)

Next invocation reads the new values silently.
