#Requires -Version 5.0

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = 'miniconda-python-env'
$snapshot = Join-Path $repoRoot ("plugins\" + $name)

Copy-Item -LiteralPath (Join-Path $repoRoot '.codex-plugin\plugin.json') -Destination (Join-Path $snapshot '.codex-plugin\plugin.json') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "skills\$name\SKILL.md") -Destination (Join-Path $snapshot "skills\$name\SKILL.md") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "skills\$name\agents\openai.yaml") -Destination (Join-Path $snapshot "skills\$name\agents\openai.yaml") -Force

Write-Host 'Codex marketplace plugin snapshot synchronized.'
