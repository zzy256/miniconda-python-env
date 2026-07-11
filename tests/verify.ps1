#Requires -Version 5.0

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-TextAbsent {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    Assert-True ($content -notmatch $Pattern) $Message
}

function Assert-TextPresent {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    Assert-True ($content -match $Pattern) $Message
}

function Get-Frontmatter {
    param([string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($content, '(?s)\A---\r?\n(?<yaml>.*?)\r?\n---')
    Assert-True $match.Success "No YAML frontmatter found in $Path"
    return $match.Groups['yaml'].Value
}

$readme = Join-Path $RepoRoot 'README.md'
$changelog = Join-Path $RepoRoot 'CHANGELOG.md'
$skill = Join-Path $RepoRoot 'skills\miniconda-python-env\SKILL.md'
$openaiYaml = Join-Path $RepoRoot 'skills\miniconda-python-env\agents\openai.yaml'
$codexMarketplace = Join-Path $RepoRoot '.agents\plugins\marketplace.json'
$setup = Join-Path $RepoRoot 'setup.ps1'
$codexPlugin = Join-Path $RepoRoot '.codex-plugin\plugin.json'
$claudePlugin = Join-Path $RepoRoot '.claude-plugin\plugin.json'
$claudeMarketplace = Join-Path $RepoRoot '.claude-plugin\marketplace.json'

$yaml = Get-Frontmatter $skill
Assert-True ($yaml -match 'description:\s*>-') 'SKILL.md description must use folded scalar frontmatter.'
$descMatch = [regex]::Match($yaml, '(?ms)^description:\s*>-\s*\r?\n(?<body>(?:[ \t]+.*(?:\r?\n|$))+)')
Assert-True $descMatch.Success 'SKILL.md description folded scalar block not found for byte check.'
$descText = ((($descMatch.Groups['body'].Value -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
$descBytes = [System.Text.Encoding]::UTF8.GetByteCount($descText)
Assert-True ($descBytes -le 1024) "SKILL.md description is $descBytes bytes; must be <= 1024 for the Codex metadata limit."
Assert-True (Test-Path -LiteralPath $openaiYaml) 'Codex agents/openai.yaml metadata is missing.'
Assert-TextPresent $openaiYaml '\$miniconda-python-env' 'openai.yaml default_prompt must explicitly mention the skill.'
$market = Get-Content -LiteralPath $codexMarketplace -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($market.plugins.Count -eq 1) 'Codex marketplace must contain exactly one independent plugin.'
Assert-True ($market.plugins[0].name -eq 'miniconda-python-env') 'Codex marketplace contains the wrong plugin.'
foreach ($rel in @('.codex-plugin\plugin.json', 'skills\miniconda-python-env\SKILL.md', 'skills\miniconda-python-env\agents\openai.yaml')) {
    $sourceText = (Get-Content -LiteralPath (Join-Path $RepoRoot $rel) -Raw -Encoding UTF8).Replace("`r`n", "`n").TrimEnd()
    $snapshotText = (Get-Content -LiteralPath (Join-Path $RepoRoot ("plugins\miniconda-python-env\" + $rel)) -Raw -Encoding UTF8).Replace("`r`n", "`n").TrimEnd()
    Assert-True ($sourceText -ceq $snapshotText) "Codex marketplace snapshot is stale: $rel"
}
$changelogText = Get-Content -LiteralPath $changelog -Raw -Encoding UTF8
$topVersionMatch = [regex]::Match($changelogText, '(?m)^## \[(?<version>\d+\.\d+\.\d+)\]')
Assert-True $topVersionMatch.Success 'CHANGELOG.md must start with a released version heading.'
$topVersion = $topVersionMatch.Groups['version'].Value
$codexVersion = (Get-Content -LiteralPath $codexPlugin -Raw -Encoding UTF8 | ConvertFrom-Json).version
$claudeVersion = (Get-Content -LiteralPath $claudePlugin -Raw -Encoding UTF8 | ConvertFrom-Json).version
$marketVersion = (Get-Content -LiteralPath $claudeMarketplace -Raw -Encoding UTF8 | ConvertFrom-Json).metadata.version
Assert-True ($codexVersion -eq $topVersion) ".codex-plugin version $codexVersion does not match changelog $topVersion."
Assert-True ($claudeVersion -eq $topVersion) ".claude-plugin version $claudeVersion does not match changelog $topVersion."
Assert-True ($marketVersion -eq $topVersion) ".claude marketplace version $marketVersion does not match changelog $topVersion."
Assert-TextAbsent $readme '\\.agents\\skills|~/\.agents/skills' 'README still references obsolete Codex .agents skill path.'
Assert-TextAbsent $setup '\\.agents\\skills|~/\.agents/skills' 'setup.ps1 still references obsolete Codex .agents skill path.'
Assert-TextAbsent $readme 'Mode B|Mode A|Mode C' 'README should use Mode 1/2/3 terminology only.'
Assert-TextAbsent $setup 'Mode B|Mode A|Mode C' 'setup.ps1 should use Mode 1/2/3 terminology only.'
Assert-TextAbsent $skill 'Mode B|Mode A|Mode C' 'SKILL.md should use Mode 1/2/3 terminology only.'
Assert-TextPresent $readme 'AI INSTALLER QUICKSTART' 'README must expose a top-level AI installer quickstart.'
Assert-TextPresent $readme 'skill: https://github\.com/zzy256/miniconda-python-env' 'README must support the one-line install request.'
Assert-TextPresent $readme 'any wording to install, add, set up, enable, configure, or use this skill' 'README quickstart must define broad equivalent trigger wording.'
Assert-TextPresent $readme 'Codex skill https://github\.com/zzy256/miniconda-python-env' 'README quickstart must include Codex skill install variant.'
Assert-TextPresent $readme 'install this skill' 'README quickstart must include English install variant.'
Assert-TextPresent $readme 'set up this Claude/Codex skill' 'README quickstart must include English setup variant.'
Assert-TextPresent $readme 'enable this skill from' 'README quickstart must include English enable variant.'
Assert-TextPresent $readme 'https://raw.githubusercontent.com/zzy256/miniconda-python-env/main/skills/miniconda-python-env/SKILL.md' 'README quickstart must include exact raw SKILL.md URL.'
Assert-TextPresent $readme 'https://raw.githubusercontent.com/zzy256/miniconda-python-env/main/skills/miniconda-python-env/agents/openai.yaml' 'README quickstart must include exact raw openai.yaml URL.'
Assert-TextPresent $readme '\.claude\\skills\\miniconda-python-env\\SKILL.md' 'README quickstart must include Claude Code skill target.'
Assert-TextPresent $readme '\.codex\\skills\\miniconda-python-env\\SKILL.md' 'README quickstart must include Codex skill target.'
Assert-TextPresent $readme '\.config\\claude-skills\\miniconda-python-env\.json' 'README quickstart must include config JSON target.'
Assert-TextPresent $readme 'ASK THE USER NOW' 'README quickstart must tell AI to ask paths immediately.'
Assert-TextPresent $readme 'DO NOT run `setup\.ps1`' 'README quickstart must forbid setup.ps1 for AI installs.'

$guard = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup 2>&1
Assert-True ($LASTEXITCODE -eq 1) 'setup.ps1 without parameters should exit 1 in redirected/non-interactive sessions.'
Assert-True (($guard | Out-String) -match 'stdin is redirected') 'setup.ps1 guard should explain redirected stdin.'

$partialTemp = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -TempEnvRoot 'D:\PyTemp' -Force 2>&1
Assert-True ($LASTEXITCODE -eq 1) 'setup.ps1 with only -TempEnvRoot should fail in redirected/non-interactive sessions.'
Assert-True (($partialTemp | Out-String) -match 'missing required path') 'partial-parameter guard should explain the missing required path.'

$partialTools = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -ToolsRoot 'D:\Tools' -Force 2>&1
Assert-True ($LASTEXITCODE -eq 1) 'setup.ps1 with only -ToolsRoot should fail in redirected/non-interactive sessions.'
Assert-True (($partialTools | Out-String) -match 'missing required path') 'partial-parameter guard should explain the missing required path.'

Assert-TextPresent $skill 'Where-Object.*prefix:' 'environment.yml export must remove the machine-specific prefix entry.'
Assert-TextPresent $skill 'Set-Content -LiteralPath .* -Encoding UTF8' 'environment.yml export must explicitly use UTF-8.'
Assert-TextAbsent $skill 'env export --prefix "<env-path>" --no-builds >' 'environment.yml export must not use PowerShell redirection.'

$testHome = Join-Path ([System.IO.Path]::GetTempPath()) ("miniconda-skill-test-" + [guid]::NewGuid())
$oldUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $testHome
    $setupOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $setup -TempEnvRoot 'C:\' -ToolsRoot 'D:\' -Agent codex -Force 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "setup.ps1 root-path test failed: $($setupOutput | Out-String)"
    $testConfig = Get-Content -LiteralPath (Join-Path $testHome '.config\claude-skills\miniconda-python-env.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($testConfig.temp_env_root -eq 'C:\') 'setup.ps1 must preserve TempEnvRoot C:\, not C:.'
    Assert-True ($testConfig.tools_root -eq 'D:\') 'setup.ps1 must preserve ToolsRoot D:\, not D:.'
    Assert-True (Test-Path -LiteralPath (Join-Path $testHome '.codex\skills\miniconda-python-env\agents\openai.yaml')) 'setup.ps1 must install the complete skill directory, including agents/openai.yaml.'
}
finally {
    $env:USERPROFILE = $oldUserProfile
    if (Test-Path -LiteralPath $testHome) { Remove-Item -LiteralPath $testHome -Recurse -Force }
}

Write-Host 'miniconda-python-env verification passed.'
