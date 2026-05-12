#Requires -Version 5.0

<#
.SYNOPSIS
Install (and configure) the miniconda-python-env skill for Claude Code
and/or Codex.

.DESCRIPTION
This script IS the install. It will:
  1. Explain what the skill does
  2. Ask you for TWO paths (with default suggestions and explanation)
  3. Generate a personalized SKILL.md and copy it to your agent's
     skills directory

After it finishes, restart your agent (Claude Code / Codex) and the
skill is live. Re-run any time with -Force to reconfigure.

.PARAMETER TempEnvRoot
Override the temp-env-root prompt. Default: D:\Projects\Claude\Temp.

.PARAMETER ToolsRoot
Override the tools-root prompt. Default: D:\Tools.

.PARAMETER Agent
Which agent to install for: 'claude', 'codex', or 'both'. Default: both.

.PARAMETER Force
Overwrite existing SKILL.md without asking.

.EXAMPLE
.\setup.ps1
Fully interactive — recommended for first-time install.

.EXAMPLE
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "D:\Tools" -Agent claude -Force
Non-interactive — useful for scripted reinstall.
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

# ----- Banner -----
Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  miniconda-python-env  — install + configure" -ForegroundColor Cyan
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
Write-Host "Before installing, I need to know TWO directories." -ForegroundColor Yellow
Write-Host ""

# ----- Locate template -----
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir 'skills\miniconda-python-env\SKILL.md.template'

if (-not (Test-Path $templatePath)) {
    Write-Error "Template not found at: $templatePath`nAre you running setup.ps1 from the cloned repo root?"
    exit 1
}

# ----- Prompt: TempEnvRoot -----
if ([string]::IsNullOrWhiteSpace($TempEnvRoot)) {
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [ Q1 ]  Temp Python env root  (Scenarios A and B)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  When a Python task is a one-off (Scenario A) or a standalone"
    Write-Host "  keeper script that doesn't belong to any project (Scenario B),"
    Write-Host "  the skill creates its env under this directory. Each task"
    Write-Host "  gets its own subfolder named '<task>-<YYYYMMDD>'."
    Write-Host ""
    Write-Host "  Examples of how the skill will use it:"
    Write-Host ""
    Write-Host "    <YOUR_ROOT>\image-ocr-20260512\" -ForegroundColor DarkGray
    Write-Host "    <YOUR_ROOT>\csv-merge-20260512\" -ForegroundColor DarkGray
    Write-Host "    <YOUR_ROOT>\yt-dlp-wrapper-20260512\" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  For Scenario A (one-off), the env subfolder is deleted right"
    Write-Host "  after the task. For Scenario B (keep & re-run), it stays."
    Write-Host ""
    Write-Host "  Common choices:"
    Write-Host "    - D:\Projects\Claude\Temp    (default)"
    Write-Host "    - D:\PyTemp"
    Write-Host "    - C:\Users\<you>\python-envs"
    Write-Host ""
    Write-Host "  Note: if this directory doesn't exist yet, the skill will ASK"
    Write-Host "  before creating it — strict scope, never silent."
    Write-Host ""
    $default = 'D:\Projects\Claude\Temp'
    $userInput = Read-Host "  Your choice [default: $default]"
    $TempEnvRoot = if ([string]::IsNullOrWhiteSpace($userInput)) { $default } else { $userInput.Trim() }
}

# Normalize and validate
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
    Write-Host "  [ Q2 ]  Tools install root  (only used if Miniconda is missing)" -ForegroundColor Green
    Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  If this skill detects that Miniconda is NOT installed on your"
    Write-Host "  machine, it will chain into the sister skill"
    Write-Host "  'windows-tools-install-manager' to install Miniconda properly."
    Write-Host "  In that case, Miniconda goes under this root:"
    Write-Host ""
    Write-Host "    <YOUR_ROOT>\miniconda\" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  IMPORTANT: this should match the InstallRoot you used when you"
    Write-Host "  set up windows-tools-install-manager. If you haven't installed"
    Write-Host "  that sister skill yet, pick a value that makes sense (you can"
    Write-Host "  always reconfigure later)."
    Write-Host ""
    Write-Host "  If Miniconda is ALREADY installed (most users), this value is"
    Write-Host "  never actually used at runtime — it's just a sensible default"
    Write-Host "  in case Miniconda gets uninstalled later."
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

# Normalize and validate
$ToolsRoot = $ToolsRoot.TrimEnd('\', '/')
if ($ToolsRoot -notmatch '^[A-Za-z]:\\') {
    Write-Warning "'$ToolsRoot' doesn't look like an absolute Windows path."
    $confirm = Read-Host "  Use it anyway? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
}

Write-Host ""
Write-Host "  ✓ ToolsRoot = $ToolsRoot" -ForegroundColor Green
Write-Host ""

# ----- Build content -----
$content = (Get-Content -Path $templatePath -Raw -Encoding UTF8) `
    .Replace('{{TEMP_ENV_ROOT}}', $TempEnvRoot) `
    .Replace('{{TOOLS_ROOT}}',    $ToolsRoot)

# ----- Resolve targets -----
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
        Path  = Join-Path $env:USERPROFILE '.agents\skills\miniconda-python-env'
    }
}

Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Installing SKILL.md ..." -ForegroundColor Green
Write-Host "------------------------------------------------------------------" -ForegroundColor DarkGray
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
    Set-Content -Path $outFile -Value $content -Encoding UTF8
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
Write-Host "       The skill should activate and propose an env plan."
Write-Host ""
Write-Host "  Sister skill recommendation:" -ForegroundColor Yellow
Write-Host "    Install 'windows-tools-install-manager' too — this skill chains"
Write-Host "    into it when Miniconda is missing."
Write-Host ""
Write-Host "  To reconfigure (different paths), re-run:" -ForegroundColor DarkGray
Write-Host "    .\setup.ps1 -TempEnvRoot 'D:\NewTemp' -ToolsRoot 'D:\NewTools' -Force" -ForegroundColor DarkGray
Write-Host ""
