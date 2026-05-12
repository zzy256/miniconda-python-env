#Requires -Version 5.0

<#
.SYNOPSIS
Install the miniconda-python-env skill for Claude Code and/or Codex.

.DESCRIPTION
Reads SKILL.md.template, substitutes path placeholders with your preferred
paths, and writes the final SKILL.md into your agent's skills folder.

.PARAMETER TempEnvRoot
Where temporary / standalone Python envs (Scenarios A and B) should be created.
Default: D:\Projects\Claude\Temp. Examples: D:\PyTemp, C:\Users\<you>\python-envs.

.PARAMETER ToolsRoot
The same root used by the windows-tools-install-manager sister skill — used
when chaining into it to install Miniconda itself if missing.
Default: D:\Tools. Examples: C:\MyTools, D:\Apps.

.PARAMETER Agent
Which agent to install the skill for: 'claude', 'codex', or 'both'.
Default: both.

.PARAMETER Force
Overwrite existing SKILL.md without prompting.

.EXAMPLE
.\setup.ps1
Interactive setup using defaults.

.EXAMPLE
.\setup.ps1 -TempEnvRoot "D:\PyTemp" -ToolsRoot "C:\MyTools" -Agent claude -Force
Non-interactive setup for Claude Code only.
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

# Locate the template (relative to this script)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir 'skills\miniconda-python-env\SKILL.md.template'

if (-not (Test-Path $templatePath)) {
    Write-Error "Template not found at: $templatePath`nAre you running setup.ps1 from the plugin repo root?"
    exit 1
}

# Prompt for TempEnvRoot if not provided
if ([string]::IsNullOrWhiteSpace($TempEnvRoot)) {
    $default = 'D:\Projects\Claude\Temp'
    Write-Host ""
    Write-Host "Where should temporary Python envs go (Scenarios A and B)?" -ForegroundColor Cyan
    Write-Host "  Examples: D:\Projects\Claude\Temp, D:\PyTemp, C:\Users\<you>\python-envs"
    $userInput = Read-Host "Path [default: $default]"
    $TempEnvRoot = if ([string]::IsNullOrWhiteSpace($userInput)) { $default } else { $userInput.Trim() }
}

# Prompt for ToolsRoot if not provided
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $default = 'D:\Tools'
    Write-Host ""
    Write-Host "Where does the windows-tools-install-manager skill install system tools?" -ForegroundColor Cyan
    Write-Host "  (Used only as the proposed install location for Miniconda itself if it's missing.)"
    Write-Host "  Examples: D:\Tools, C:\MyTools"
    $userInput = Read-Host "Path [default: $default]"
    $ToolsRoot = if ([string]::IsNullOrWhiteSpace($userInput)) { $default } else { $userInput.Trim() }
}

# Normalize: strip trailing slashes
$TempEnvRoot = $TempEnvRoot.TrimEnd('\', '/')
$ToolsRoot   = $ToolsRoot.TrimEnd('\', '/')

# Validate they look like absolute Windows paths
foreach ($p in @(@{ name = 'TempEnvRoot'; value = $TempEnvRoot }, @{ name = 'ToolsRoot'; value = $ToolsRoot })) {
    if ($p.value -notmatch '^[A-Za-z]:\\') {
        Write-Warning "$($p.name) '$($p.value)' doesn't look like an absolute Windows path (e.g., 'D:\Tools')."
        $confirm = Read-Host "Use it anyway? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') { exit 1 }
    }
}

Write-Host ""
Write-Host "Configured:" -ForegroundColor Cyan
Write-Host "  TempEnvRoot = $TempEnvRoot"
Write-Host "  ToolsRoot   = $ToolsRoot"
Write-Host "  Agent       = $Agent"
Write-Host ""

# Read template and substitute placeholders (literal string replace, not regex)
$content = (Get-Content -Path $templatePath -Raw -Encoding UTF8) `
    .Replace('{{TEMP_ENV_ROOT}}', $TempEnvRoot) `
    .Replace('{{TOOLS_ROOT}}',    $ToolsRoot)

# Determine target installation locations
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

# Install
foreach ($target in $targets) {
    $outFile = Join-Path $target.Path 'SKILL.md'

    if ((Test-Path $outFile) -and -not $Force) {
        Write-Host "[$($target.Agent)] SKILL.md already exists at: $outFile" -ForegroundColor Yellow
        $confirm = Read-Host "  Overwrite? [y/N]"
        if ($confirm -ne 'y' -and $confirm -ne 'Y') {
            Write-Host "  Skipped." -ForegroundColor DarkYellow
            continue
        }
    }

    New-Item -ItemType Directory -Path $target.Path -Force | Out-Null
    Set-Content -Path $outFile -Value $content -Encoding UTF8
    Write-Host "[$($target.Agent)] Installed: $outFile" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Restart Claude Code / Codex to pick up the skill." -ForegroundColor Yellow
Write-Host "Tip: install the sister skill 'windows-tools-install-manager' too — this skill chains into it" -ForegroundColor DarkGray
Write-Host "     when Miniconda is missing." -ForegroundColor DarkGray
