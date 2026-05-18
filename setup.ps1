#Requires -Version 5.0

<#
.SYNOPSIS
[Mode B install] Pre-configure paths AND copy the skill to your agent.

.DESCRIPTION
This is the "power user" install path. It does TWO things:
  1. Pre-fills the skill's config file at:
     $env:USERPROFILE\.config\claude-skills\miniconda-python-env.json
     ...so the skill won't prompt you for paths on first use.
  2. Copies the skill's SKILL.md into your agent's skills directory.

If you'd rather have the skill ask you on first trigger (Mode A or C), you
don't need this script — just install the plugin via `/plugin install` or
have an AI drop SKILL.md for you. See README.md.

.PARAMETER TempEnvRoot
Where temp/standalone Python envs live. Default: D:\Projects\Claude\Temp.

.PARAMETER ToolsRoot
Same root the sister skill windows-tools-install-manager uses; only consulted
if Miniconda needs to be installed. Default: D:\Tools.

.PARAMETER Agent
'claude' / 'codex' / 'both'. Default: both.

.PARAMETER Force
Overwrite existing SKILL.md and config without asking.

.EXAMPLE
.\setup.ps1
Fully interactive.

.EXAMPLE
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
Non-interactive.
#>

[CmdletBinding()]
param(
    [string]$TempEnvRoot,
    [string]$ToolsRoot,
    [ValidateSet('claude', 'codex', 'both')]
    [string]$Agent = 'both',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ----- AI-agent / non-interactive guard -----
# If stdin is redirected (AI tool call context) AND neither path parameter was
# passed, Read-Host silently returns empty and the script falls back to defaults
# — meaning the user never gets asked. Refuse to proceed in that case.
if ([string]::IsNullOrWhiteSpace($TempEnvRoot) -and [string]::IsNullOrWhiteSpace($ToolsRoot) -and [System.Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Red
    Write-Host "  setup.ps1 cannot run interactively here (stdin is redirected)." -ForegroundColor Red
    Write-Host "==================================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "You appear to be running setup.ps1 inside an AI agent's tool call"
    Write-Host "(Codex, Claude Code's Bash, etc.). The script's interactive Read-Host"
    Write-Host "prompts WILL NOT reach the human user — they'll silently return empty"
    Write-Host "and the script will use defaults without asking. That's a UX bug."
    Write-Host ""
    Write-Host "If you are an AI agent installing this skill for a user:" -ForegroundColor Yellow
    Write-Host "  Use Mode 1 in the README instead — fetch SKILL.md directly via"
    Write-Host "  raw.githubusercontent.com, ASK the user for TempEnvRoot + ToolsRoot,"
    Write-Host "  then write the config JSON file at"
    Write-Host "  ~/.config/claude-skills/miniconda-python-env.json"
    Write-Host "  (full prompt template in README's '⭐ Mode 1' section)."
    Write-Host ""
    Write-Host "If you are a human running this from a real terminal:" -ForegroundColor Yellow
    Write-Host "  Either invoke from an interactive PowerShell (no piping/redirect),"
    Write-Host "  or pass paths explicitly:"
    Write-Host "    .\setup.ps1 -TempEnvRoot 'D:\Projects\Claude\Temp' -ToolsRoot 'D:\Tools' -Force"
    Write-Host ""
    exit 1
}

# ----- Banner -----
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  miniconda-python-env  — Mode B install (pre-config)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This skill standardizes how your AI agent uses Python: every Python"
Write-Host "task gets its own isolated Miniconda env, with auto-classification"
Write-Host "into one of three scenarios and strict cleanup rules:"
Write-Host ""
Write-Host "  A. Temp script         - env auto-deleted after task"
Write-Host "  B. Standalone keeper   - env kept + environment.yml generated"
Write-Host "  C. Formal project      - env lives inside the project root"
Write-Host ""
Write-Host "Mode B (this script) lets you set the paths upfront, so the skill"
Write-Host "won't ask the first time you use it." -ForegroundColor Yellow
Write-Host ""

# ----- Locate skill file -----
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillSource = Join-Path $scriptDir 'skills\miniconda-python-env\SKILL.md'

if (-not (Test-Path $skillSource)) {
    Write-Error "SKILL.md not found at: $skillSource`nAre you running setup.ps1 from the cloned repo root?"
    exit 1
}

# ----- Prompt: TempEnvRoot -----
if ([string]::IsNullOrWhiteSpace($TempEnvRoot)) {
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [ Q1 ]  Temp Python env root  (Scenarios A and B)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Where to put env subfolders for one-off (Scenario A) and"
    Write-Host "  standalone keeper (Scenario B) Python tasks. Each task gets"
    Write-Host "  its own subfolder named '<task>-<YYYYMMDD>'."
    Write-Host ""
    Write-Host "  Examples:"
    Write-Host "    <YOUR_ROOT>\image-ocr-20260512\" -ForegroundColor DarkGray
    Write-Host "    <YOUR_ROOT>\csv-merge-20260512\" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Common choices:"
    Write-Host "    - D:\Projects\Claude\Temp    (default)"
    Write-Host "    - D:\PyTemp"
    Write-Host "    - C:\Users\<you>\python-envs"
    Write-Host ""
    $default = 'D:\Projects\Claude\Temp'
    $userInput = Read-Host "  Your choice [default: $default]"
    $TempEnvRoot = if ([string]::IsNullOrWhiteSpace($userInput)) { $default } else { $userInput.Trim() }
}

$TempEnvRoot = $TempEnvRoot.TrimEnd('\', '/')
if ($TempEnvRoot -notmatch '^[A-Za-z]:\\') {
    Write-Warning "'$TempEnvRoot' doesn't look like an absolute Windows path."
    $confirm = Read-Host "  Use it anyway? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
}

Write-Host ""
Write-Host "  ✓ TempEnvRoot = $TempEnvRoot" -ForegroundColor Green
Write-Host ""

# ----- Prompt: ToolsRoot -----
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [ Q2 ]  Tools install root  (only used if Miniconda missing)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  If Miniconda isn't installed, this skill chains into the sister"
    Write-Host "  skill windows-tools-install-manager to install it under:"
    Write-Host ""
    Write-Host "    <YOUR_ROOT>\miniconda\" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Should match the InstallRoot used by windows-tools-install-manager."
    Write-Host "  If Miniconda is already installed (most users), this value is"
    Write-Host "  unused at runtime — but worth setting in case Miniconda gets"
    Write-Host "  uninstalled later."
    Write-Host ""
    Write-Host "  Common choices:"
    Write-Host "    - D:\Tools         (default)"
    Write-Host "    - C:\MyTools"
    Write-Host "    - D:\Apps"
    Write-Host ""
    $default = 'D:\Tools'
    $userInput = Read-Host "  Your choice [default: $default]"
    $ToolsRoot = if ([string]::IsNullOrWhiteSpace($userInput)) { $default } else { $userInput.Trim() }
}

$ToolsRoot = $ToolsRoot.TrimEnd('\', '/')
if ($ToolsRoot -notmatch '^[A-Za-z]:\\') {
    Write-Warning "'$ToolsRoot' doesn't look like an absolute Windows path."
    $confirm = Read-Host "  Use it anyway? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
}

Write-Host ""
Write-Host "  ✓ ToolsRoot = $ToolsRoot" -ForegroundColor Green
Write-Host ""

# ----- Step 1: write config file -----
$cfgDir = Join-Path $env:USERPROFILE '.config\claude-skills'
$cfgPath = Join-Path $cfgDir 'miniconda-python-env.json'

if ((Test-Path $cfgPath) -and -not $Force) {
    Write-Host "  Config already exists at: $cfgPath" -ForegroundColor Yellow
    $existing = Get-Content $cfgPath -Raw | ConvertFrom-Json
    Write-Host "    current temp_env_root = $($existing.temp_env_root)" -ForegroundColor DarkGray
    Write-Host "    current tools_root    = $($existing.tools_root)" -ForegroundColor DarkGray
    $confirm = Read-Host "  Overwrite with new values? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "  Skipped config write." -ForegroundColor DarkYellow
    }
    else {
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        @{ temp_env_root = $TempEnvRoot; tools_root = $ToolsRoot } |
            ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Host "  ✓ Wrote config: $cfgPath" -ForegroundColor Green
    }
}
else {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    @{ temp_env_root = $TempEnvRoot; tools_root = $ToolsRoot } |
        ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
    Write-Host "  ✓ Wrote config: $cfgPath" -ForegroundColor Green
}

# ----- Step 2: copy SKILL.md to agent skill dirs -----
$targets = @()
if ($Agent -in @('claude', 'both')) {
    $targets += [PSCustomObject]@{
        Agent = 'Claude Code'
        Path  = Join-Path $env:USERPROFILE '.claude\skills\miniconda-python-env'
    }
}
if ($Agent -in @('codex', 'both')) {
    $targets += [PSCustomObject]@{
        Agent = 'Codex'
        Path  = Join-Path $env:USERPROFILE '.codex\skills\miniconda-python-env'
    }
}

Write-Host ""
foreach ($target in $targets) {
    $outFile = Join-Path $target.Path 'SKILL.md'

    if ((Test-Path $outFile) -and -not $Force) {
        Write-Host "  [$($target.Agent)] $outFile already exists." -ForegroundColor Yellow
        $confirm = Read-Host "  Overwrite? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "  Skipped." -ForegroundColor DarkYellow
            continue
        }
    }

    New-Item -ItemType Directory -Path $target.Path -Force | Out-Null
    Copy-Item -Path $skillSource -Destination $outFile -Force
    Write-Host "  ✓ [$($target.Agent)] $outFile" -ForegroundColor Green
}

# ----- Summary -----
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Install complete." -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Restart Claude Code / Codex (close and reopen)"
Write-Host "    2. Try saying:  '用 Python 处理这个 CSV'  or  'install pandas'"
Write-Host "       The skill should activate, read the config, and propose"
Write-Host "       an env plan WITHOUT asking you for paths."
Write-Host ""
Write-Host "  Sister skill recommendation:" -ForegroundColor Yellow
Write-Host "    Install 'windows-tools-install-manager' too — this skill chains"
Write-Host "    into it when Miniconda is missing."
Write-Host ""
Write-Host "  To change paths later:" -ForegroundColor DarkGray
Write-Host "    .\setup.ps1 -TempEnvRoot 'D:\NewTemp' -ToolsRoot 'D:\NewTools' -Force" -ForegroundColor DarkGray
Write-Host "    (or just edit $cfgPath directly)" -ForegroundColor DarkGray
Write-Host ""
