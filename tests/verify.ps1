#Requires -Version 5.0

$ErrorActionPreference = 'Stop'
$env:MINICONDA_PYTHON_ENV_TEST_MODE = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$CheckoutSha = '34e114876b0b11c390a56381ad16ebd13914f8d5'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-TextPresent {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    Assert-True ($content -match $Pattern) $Message
}

function Assert-TextAbsent {
    param([string]$Path, [string]$Pattern, [string]$Message)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    Assert-True ($content -notmatch $Pattern) $Message
}

function Get-Frontmatter {
    param([string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($content, '(?s)\A---\r?\n(?<yaml>.*?)\r?\n---')
    Assert-True $match.Success "No YAML frontmatter found in $Path"
    return $match.Groups['yaml'].Value
}

function ConvertTo-PowerShellLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-RedirectedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Environment = @{},
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        [ValidateSet('Bypass', 'Restricted', 'Default')][string]$ExecutionPolicy = 'Bypass'
    )

    $environmentPrefix = ''
    foreach ($entry in $Environment.GetEnumerator()) {
        $key = [string]$entry.Key
        Assert-True ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') "Unsafe child environment name: $key"
        $environmentPrefix += '$env:' + $key + ' = ' + (ConvertTo-PowerShellLiteral ([string]$entry.Value)) + '; '
    }
    if ($ExecutionPolicy -ceq 'Default') {
        $environmentPrefix += 'Remove-Item Env:\PSExecutionPolicyPreference -ErrorAction SilentlyContinue; '
    }
    $prefix = '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ' +
        $environmentPrefix + '$ErrorActionPreference = ''Stop''; '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix + $Command))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $executionPolicyArgument = if ($ExecutionPolicy -ceq 'Default') { '' } `
        else { "-ExecutionPolicy $ExecutionPolicy " }
    $psi.Arguments = "-NoProfile $executionPolicyArgument-EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        Assert-True $process.Start() 'Failed to start Windows PowerShell child process.'
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F 2>$null | Out-Null }
            catch {}
            if (-not $process.HasExited) { try { $process.Kill() } catch {} }
            $process.WaitForExit()
            throw "Windows PowerShell child timed out after $TimeoutSeconds seconds: $Command"
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Output = $stdout + $stderr
        }
    }
    finally {
        $process.Dispose()
    }
}

function Start-RedirectedPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [hashtable]$Environment = @{}
    )

    $environmentPrefix = ''
    foreach ($entry in $Environment.GetEnumerator()) {
        $key = [string]$entry.Key
        Assert-True ($key -match '^[A-Za-z_][A-Za-z0-9_]*$') "Unsafe child environment name: $key"
        $environmentPrefix += '$env:' + $key + ' = ' + (ConvertTo-PowerShellLiteral ([string]$entry.Value)) + '; '
    }
    $prefix = '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ' +
        $environmentPrefix + '$ErrorActionPreference = ''Stop''; '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix + $Command))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    Assert-True $process.Start() 'Failed to start asynchronous Windows PowerShell child process.'
    $process.StandardInput.Close()
    return [PSCustomObject]@{
        Process = $process
        StdOutTask = $process.StandardOutput.ReadToEndAsync()
        StdErrTask = $process.StandardError.ReadToEndAsync()
        Command = $Command
    }
}

function Complete-RedirectedPowerShell {
    param(
        [Parameter(Mandatory = $true)]$Handle,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30
    )

    try {
        if (-not $Handle.Process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & "$env:SystemRoot\System32\taskkill.exe" /PID $Handle.Process.Id /T /F 2>$null | Out-Null }
            catch {}
            if (-not $Handle.Process.HasExited) { try { $Handle.Process.Kill() } catch {} }
            $Handle.Process.WaitForExit()
            throw "Asynchronous Windows PowerShell child timed out: $($Handle.Command)"
        }
        $stdout = $Handle.StdOutTask.Result
        $stderr = $Handle.StdErrTask.Result
        return [PSCustomObject]@{
            ExitCode = $Handle.Process.ExitCode
            StdOut = $stdout
            StdErr = $stderr
            Output = $stdout + $stderr
        }
    }
    finally { $Handle.Process.Dispose() }
}

function Remove-TestTree {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force }
    catch {
        $full = [IO.Path]::GetFullPath($Path)
        [IO.Directory]::Delete('\\?\' + $full, $true)
    }
}

function Assert-PowerShellParses {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "$Path has PowerShell parse errors: $($errors -join '; ')"
}

function Get-RelativeEntrySet {
    param([string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
            $relative = $_.FullName.Substring($rootFull.Length).Replace('\', '/')
            if ($_.PSIsContainer) { "D:$relative" } else { "F:$relative" }
        } | Sort-Object
    )
}

function Get-TreeFingerprint {
    param([string]$Root)
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File | ForEach-Object {
            $relative = $_.FullName.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\').Length + 1).Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            "$relative=$hash"
        } | Sort-Object
    ) -join "`n"
}

$readme = Join-Path $RepoRoot 'README.md'
$changelog = Join-Path $RepoRoot 'CHANGELOG.md'
$skillRoot = Join-Path $RepoRoot 'skills\miniconda-python-env'
$skill = Join-Path $skillRoot 'SKILL.md'
$environmentHelpers = Join-Path $skillRoot 'scripts\EnvironmentHelpers.ps1'
$creationReference = Join-Path $skillRoot 'references\creation-transaction.md'
$manifestReference = Join-Path $skillRoot 'references\project-manifests.md'
$openaiYaml = Join-Path $skillRoot 'agents\openai.yaml'
$codexMarketplace = Join-Path $RepoRoot '.agents\plugins\marketplace.json'
$setup = Join-Path $RepoRoot 'setup.ps1'
$sync = Join-Path $RepoRoot 'sync-codex-plugin.ps1'
$codexPlugin = Join-Path $RepoRoot '.codex-plugin\plugin.json'
$claudePlugin = Join-Path $RepoRoot '.claude-plugin\plugin.json'
$claudeMarketplace = Join-Path $RepoRoot '.claude-plugin\marketplace.json'
$snapshotRoot = Join-Path $RepoRoot 'plugins\miniconda-python-env'
$verifyWorkflow = Join-Path $RepoRoot '.github\workflows\verify.yml'
$releaseWorkflow = Join-Path $RepoRoot '.github\workflows\release.yml'
$gitattributes = Join-Path $RepoRoot '.gitattributes'

Write-Host '[1/7] Metadata, manifests, scripts, and documentation'
Assert-PowerShellParses $setup
Assert-PowerShellParses $sync
Assert-PowerShellParses $environmentHelpers
$helperTokens = $null; $helperErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile(
    $environmentHelpers, [ref]$helperTokens, [ref]$helperErrors)
$helperTopLevelEffects = @($helperAst.EndBlock.Statements | Where-Object {
    $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
})
Assert-True ($helperTopLevelEffects.Count -eq 0) 'Dot-sourcing the helper must only define functions, not mutate caller session state.'
foreach ($scriptPath in @($setup, $sync, $environmentHelpers, $PSCommandPath)) {
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
    Assert-True (-not [regex]::IsMatch($scriptText, '[^\x00-\x7F]')) "$scriptPath must remain ASCII-only for Windows PowerShell 5.1."
}

$yaml = Get-Frontmatter $skill
Assert-True ($yaml -match 'description:\s*>-') 'SKILL.md description must use folded scalar frontmatter.'
$descMatch = [regex]::Match($yaml, '(?ms)^description:\s*>-\s*\r?\n(?<body>(?:[ \t]+.*(?:\r?\n|$))+)')
Assert-True $descMatch.Success 'SKILL.md description folded scalar block not found.'
$descText = ((($descMatch.Groups['body'].Value -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
$descBytes = [Text.Encoding]::UTF8.GetByteCount($descText)
Assert-True ($descBytes -le 900) "SKILL.md description is $descBytes bytes; keep comfortable headroom below 1024."
Assert-True ($descText -notmatch '[<>]') 'SKILL.md description must not contain angle brackets rejected by Codex skill validation.'
foreach ($manager in @('Pixi', 'Hatch', 'Rye')) {
    Assert-True ($descText -match [regex]::Escape($manager)) "Trigger metadata omits $manager ownership."
}
Assert-True ($descText -match 'Project pip/pytest work' -and
    $descText -match 'persistent global/end-user CLI' -and $descText -match 'pipx') 'Trigger metadata does not separate project Python work from persistent global CLIs.'
Assert-True ($descText -match 'read-only interpreter locate/version/status checks') 'Trigger metadata does not exclude read-only interpreter inspection.'
$skillLines = (Get-Content -LiteralPath $skill -Encoding UTF8).Count
Assert-True ($skillLines -lt 500) "SKILL.md is $skillLines lines; keep it below 500 lines."
foreach ($reference in @($creationReference, $manifestReference)) {
    Assert-True (Test-Path -LiteralPath $reference -PathType Leaf) "Required skill reference is missing: $reference"
}
Assert-True (Test-Path -LiteralPath $openaiYaml -PathType Leaf) 'Codex agents/openai.yaml metadata is missing.'
Assert-TextPresent $openaiYaml '\$miniconda-python-env' 'openai.yaml default_prompt must explicitly mention the skill.'

$market = Get-Content -LiteralPath $codexMarketplace -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($market.plugins.Count -eq 1) 'Codex marketplace must contain exactly one independent plugin.'
Assert-True ($market.plugins[0].name -eq 'miniconda-python-env') 'Codex marketplace contains the wrong plugin.'
$claudeMarket = Get-Content -LiteralPath $claudeMarketplace -Raw -Encoding UTF8 | ConvertFrom-Json
$claudeEntry = $claudeMarket.plugins[0]
Assert-True ($claudeEntry.source -eq './') 'Claude marketplace must point at the repository plugin root.'
Assert-True (-not ($claudeEntry.PSObject.Properties.Name -contains 'strict' -and $claudeEntry.strict -eq $false)) 'Claude marketplace strict:false conflicts with the root plugin manifest.'
Assert-True (-not ($claudeEntry.PSObject.Properties.Name -contains 'skills')) 'Claude marketplace must not redefine skills already discovered from the plugin root.'

Write-Host '[2/7] Exact Codex snapshot mirror and sync recovery'
$expectedStage = Join-Path ([IO.Path]::GetTempPath()) ('mini-expected-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path (Join-Path $expectedStage '.codex-plugin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $expectedStage 'skills') -Force | Out-Null
    Copy-Item -LiteralPath $codexPlugin -Destination (Join-Path $expectedStage '.codex-plugin\plugin.json')
    Copy-Item -LiteralPath $skillRoot -Destination (Join-Path $expectedStage 'skills\miniconda-python-env') -Recurse
    $expectedEntries = Get-RelativeEntrySet $expectedStage
    $snapshotEntries = Get-RelativeEntrySet $snapshotRoot
    Assert-True (($expectedEntries -join "`n") -ceq ($snapshotEntries -join "`n")) 'Codex snapshot entry set is stale or contains extra files.'
    foreach ($entry in $expectedEntries | Where-Object { $_.StartsWith('F:') }) {
        $relative = $entry.Substring(2).Replace('/', '\')
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $expectedStage $relative) -Algorithm SHA256).Hash
        $snapshotHash = (Get-FileHash -LiteralPath (Join-Path $snapshotRoot $relative) -Algorithm SHA256).Hash
        Assert-True ($sourceHash -ceq $snapshotHash) "Codex marketplace snapshot is stale: $relative"
    }
}
finally { Remove-TestTree $expectedStage }

$syncLiteral = ConvertTo-PowerShellLiteral $sync
$snapshotBefore = Get-TreeFingerprint $snapshotRoot
$syncSourceMutation = Invoke-RedirectedPowerShell "& $syncLiteral" @{
    MINICONDA_PYTHON_ENV_SYNC_TEST_MUTATE_SOURCE_DURING_STAGE = '1'
}
Assert-True ($syncSourceMutation.ExitCode -eq 1) 'A source mutation during snapshot staging should fail.'
Assert-True ($syncSourceMutation.Output -match 'Skill source fingerprint changed') 'Snapshot sync did not report the staged-source race.'
Assert-True ((Get-TreeFingerprint $snapshotRoot) -ceq $snapshotBefore) 'A source mutation during staging changed the canonical snapshot.'
Assert-True (@(Get-ChildItem -LiteralPath $skillRoot -Force |
    Where-Object { $_.Name -match '^\.sync-source-mutation-[0-9a-f]{32}$' }).Count -eq 0) 'Snapshot source-mutation hook left a marker in the source tree.'
$sourceRaceResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
    Where-Object { $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' })
Assert-True ($sourceRaceResidue.Count -eq 0) 'Source-race rejection left snapshot transaction residue.'

$syncFailure = Invoke-RedirectedPowerShell "& $syncLiteral" @{
    MINICONDA_PYTHON_ENV_SYNC_TEST_FAIL_AFTER_BACKUP = '1'
}
Assert-True ($syncFailure.ExitCode -eq 1) 'Injected snapshot-sync failure should exit 1.'
Assert-True ($syncFailure.Output -match 'Simulated sync failure') 'Injected sync failure did not reach the post-backup boundary.'
Assert-True ((Get-TreeFingerprint $snapshotRoot) -ceq $snapshotBefore) 'Snapshot sync rollback did not restore the canonical snapshot byte-for-byte.'
$syncResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
    Where-Object { $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' })
Assert-True ($syncResidue.Count -eq 0) 'Snapshot sync rollback left stage/backup residue.'

$residueBeforeTamper = @($syncResidue | ForEach-Object { $_.FullName })
try {
    $syncTamper = Invoke-RedirectedPowerShell "& $syncLiteral" @{
        MINICONDA_PYTHON_ENV_SYNC_TEST_MUTATE_BACKUP_BEFORE_ROLLBACK = '1'
    }
    Assert-True ($syncTamper.ExitCode -eq 1) 'Fingerprint-mutated snapshot rollback should fail closed.'
    Assert-True ($syncTamper.Output -match 'fingerprint changed') 'Snapshot rollback did not report the backup fingerprint mismatch.'
    Assert-True (Test-Path -LiteralPath $snapshotRoot -PathType Container) 'Fingerprint mismatch deleted the current canonical snapshot.'
    Assert-True ((Get-TreeFingerprint $snapshotRoot) -ceq $snapshotBefore) 'Fingerprint mismatch changed the preserved canonical snapshot.'
    $tamperResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
        Where-Object { $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' })
    Assert-True (($tamperResidue | Where-Object { $_.Name -match '\.backup-' }).Count -eq 1) 'Mutated rollback backup was not preserved for manual recovery.'
}
finally {
    Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
        Where-Object {
            $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' -and
            $_.FullName -notin $residueBeforeTamper
        } | ForEach-Object { Remove-TestTree $_.FullName }
}

foreach ($canonicalMode in @('content', 'type')) {
    $canonicalResidueBefore = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
        Where-Object { $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' } |
        ForEach-Object { $_.FullName })
    $canonicalBackup = $null
    try {
        $canonicalTamper = Invoke-RedirectedPowerShell "& $syncLiteral" @{
            MINICONDA_PYTHON_ENV_SYNC_TEST_INVALIDATE_CANONICAL_MODE = $canonicalMode
        }
        Assert-True ($canonicalTamper.ExitCode -eq 1) "A $canonicalMode-mutated canonical snapshot must fail closed."
        Assert-True ($canonicalTamper.Output -match 'Committed canonical snapshot') "Canonical $canonicalMode mutation did not report an ownership mismatch."
        if ($canonicalMode -ceq 'content') {
            Assert-True (Test-Path -LiteralPath $snapshotRoot -PathType Container) 'Content-mutated canonical snapshot was deleted.'
        } else {
            Assert-True (Test-Path -LiteralPath $snapshotRoot -PathType Leaf) 'Type-mutated canonical snapshot was deleted.'
        }
        $canonicalResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
            Where-Object {
                $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' -and
                $_.FullName -notin $canonicalResidueBefore
            })
        $canonicalBackups = @($canonicalResidue | Where-Object { $_.Name -match '\.backup-' })
        Assert-True ($canonicalBackups.Count -eq 1) "Canonical $canonicalMode mutation did not preserve exactly one rollback backup."
        $canonicalBackup = $canonicalBackups[0]
        Assert-True ((Get-TreeFingerprint $canonicalBackup.FullName) -ceq $snapshotBefore) "Canonical $canonicalMode mutation changed the preserved rollback backup."
    }
    finally {
        if ($canonicalBackup -and (Test-Path -LiteralPath $canonicalBackup.FullName -PathType Container)) {
            Remove-TestTree $snapshotRoot
            [IO.Directory]::Move($canonicalBackup.FullName, $snapshotRoot)
        }
        Get-ChildItem -LiteralPath (Split-Path -Parent $snapshotRoot) -Force |
            Where-Object {
                $_.Name -match '^\.miniconda-python-env\.(stage|backup)-[0-9a-f]{32}$' -and
                $_.FullName -notin $canonicalResidueBefore
            } | ForEach-Object { Remove-TestTree $_.FullName }
    }
    Assert-True ((Get-TreeFingerprint $snapshotRoot) -ceq $snapshotBefore) "Canonical snapshot was not restored after the $canonicalMode ownership test."
}

$syncMutexName = 'Local\mini-sync-verify-' + [guid]::NewGuid().ToString('N')
$heldSyncMutex = New-Object Threading.Mutex($false, $syncMutexName)
$ownsSyncMutex = $heldSyncMutex.WaitOne(0)
try {
    Assert-True $ownsSyncMutex 'Test process could not acquire the sync mutex.'
    $syncLocked = Invoke-RedirectedPowerShell "& $syncLiteral" @{
        MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_NAME = $syncMutexName
        MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_TIMEOUT_SECONDS = '1'
    } 10
    Assert-True ($syncLocked.ExitCode -eq 1) 'A second sync process must time out while the canonical lock is held.'
    Assert-True ($syncLocked.Output -match 'Timed out waiting') 'Sync mutex timeout must be actionable.'
    Assert-True ((Get-TreeFingerprint $snapshotRoot) -ceq $snapshotBefore) 'A timed-out sync process changed the snapshot.'
}
finally {
    if ($ownsSyncMutex) { $heldSyncMutex.ReleaseMutex() }
    $heldSyncMutex.Dispose()
}
$syncAfterRelease = Invoke-RedirectedPowerShell "& $syncLiteral" @{
    MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_NAME = $syncMutexName
    MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_TIMEOUT_SECONDS = '2'
}
Assert-True ($syncAfterRelease.ExitCode -eq 0) "Sync lock was not reusable after release: $($syncAfterRelease.Output)"

$changelogText = Get-Content -LiteralPath $changelog -Raw -Encoding UTF8
$topVersionMatch = [regex]::Match($changelogText, '(?m)^## \[(?<version>\d+\.\d+\.\d+)\]')
Assert-True $topVersionMatch.Success 'CHANGELOG.md must start with a released version heading.'
$topVersion = $topVersionMatch.Groups['version'].Value
$codexVersion = (Get-Content -LiteralPath $codexPlugin -Raw -Encoding UTF8 | ConvertFrom-Json).version
$claudeVersion = (Get-Content -LiteralPath $claudePlugin -Raw -Encoding UTF8 | ConvertFrom-Json).version
$marketVersion = $claudeMarket.metadata.version
Assert-True ($codexVersion -eq $topVersion) ".codex-plugin version $codexVersion does not match changelog $topVersion."
Assert-True ($claudeVersion -eq $topVersion) ".claude-plugin version $claudeVersion does not match changelog $topVersion."
Assert-True ($marketVersion -eq $topVersion) ".claude marketplace version $marketVersion does not match changelog $topVersion."

Write-Host '[3/7] Skill lifecycle, dependency, cleanup, and release policy'
Assert-TextAbsent $readme '\.agents\\skills|~/\.agents/skills' 'README references the obsolete Codex .agents skill path.'
Assert-TextAbsent $setup '\.agents\\skills|~/\.agents/skills' 'setup.ps1 references the obsolete Codex .agents skill path.'
Assert-TextPresent $readme 'AI INSTALLER QUICKSTART' 'README must expose the AI installer quickstart.'
Assert-TextPresent $readme 'codex\.cmd plugin marketplace add' 'README must use the Windows-safe codex.cmd form.'
Assert-TextPresent $readme 'transactional flow instead of copying individual files' 'README AI install must use the transactional setup flow.'
Assert-TextPresent $readme 'https://github\.com/zzy256/miniconda-python-env\.git#v1\.2\.0' 'Claude install must use an HTTPS URL pinned to the release tag.'
Assert-TextPresent $readme 'verification\.verified' 'README must require GitHub verified-tag status.'
Assert-TextPresent $readme 'tagObject\.object\.sha' 'README must compare local HEAD with the verified tag target.'
Assert-TextAbsent $readme 'raw\.githubusercontent\.com/.*/main/' 'README installation must not fetch mutable main resources.'
Assert-TextPresent $readme 'marketplace add zzy256/miniconda-python-env --ref v1\.2\.0' 'Codex install must pin the release tag.'
Assert-TextPresent $readme 'Signed release checklist' 'README must contain the signed release checklist.'
Assert-TextPresent $readme '<script-slug>-<script-path-hash>' 'README must document the stable STANDALONE path contract.'
Assert-TextPresent $readme 'Pixi/Hatch/Rye' 'README must document newly detected Python managers.'
Assert-TextPresent $readme 'same-directory mutex/CAS writer' 'README must document atomic manifest replacement.'
foreach ($workflow in @($verifyWorkflow, $releaseWorkflow)) {
    Assert-TextPresent $workflow ([regex]::Escape("actions/checkout@$CheckoutSha")) 'Workflows must pin actions/checkout to the reviewed commit.'
    Assert-TextPresent $workflow 'timeout-minutes:\s*15' 'Every workflow job needs a bounded timeout.'
}
Assert-TextPresent $releaseWorkflow 'verification\.verified' 'Release workflow must require GitHub-verified signed tags.'
Assert-TextPresent $releaseWorkflow 'object\.type -cne ''commit''' 'Release workflow must require the signed tag to point directly to a commit.'
Assert-TextPresent $releaseWorkflow '\$LASTEXITCODE -ne 0.*Could not inspect' 'Release workflow must check GitHub API command failures before JSON parsing.'
Assert-TextPresent $releaseWorkflow 'gh release create.*--verify-tag' 'Release workflow must verify the remote tag before creating a release.'
Assert-TextPresent $releaseWorkflow 'GitHub Release creation failed' 'Release workflow must propagate gh release failures explicitly.'
Assert-TextPresent $releaseWorkflow 'persist-credentials:\s*false' 'Repository tests must not retain checkout credentials.'
Assert-TextPresent $releaseWorkflow 'git rev-parse HEAD' 'Release workflow must inspect the exact checked-out commit.'
Assert-TextPresent $releaseWorkflow 'HEAD does not match the GitHub-verified signed tag target' 'Release workflow must bind the checkout to the verified tag target.'
Assert-TextPresent $releaseWorkflow '(?s)verify:.*?contents:\s*read.*?release:.*?needs:\s*verify.*?contents:\s*write' 'Only the post-verification release job may receive contents:write.'
$releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflow -Raw -Encoding UTF8
Assert-True ($releaseWorkflowText.IndexOf('- name: Check tag and manifest version') -lt $releaseWorkflowText.IndexOf('- name: Run PowerShell verification')) 'Release workflow must authenticate the signed tag before executing repository test code.'
Assert-TextPresent $setup 'Get-ChildItem[^\r\n]+-ErrorAction Stop' 'Setup residue enumeration must fail closed when a directory cannot be listed.'
Assert-TextPresent $setup '\$invalidStates = New-Object' 'Setup rollback must preflight backup, stage, and canonical ownership before deleting state.'
Assert-TextPresent $sync 'Get-ChildItem[^\r\n]+-ErrorAction Stop' 'Sync residue enumeration must fail closed when the plugins directory cannot be listed.'
Assert-TextPresent $sync '(?s)if \(\$canonicalMutationStarted\).*?Assert-SyncPathMatches -Path \$snapshot.*?Remove-Item -LiteralPath \$snapshot' 'Sync recovery must verify canonical ownership before deleting the canonical snapshot.'
Assert-TextPresent $sync '\$preserveStageForRecovery = \$true' 'Sync must preserve staging when its rollback backup disappeared.'
Assert-TextPresent $setup 'ExpectedFingerprint' 'Setup journal must record rollback backup fingerprints.'
Assert-TextPresent $setup '\[IO\.Directory\]::Move\(\$sameDirectoryStage, \$target\.Path\)' 'Setup skill replacement must atomically rename a same-directory stage.'
Assert-TextPresent $setup '\[IO\.File\]::Move\(\$sameDirectoryStage, \$cfgPath\)' 'Setup config replacement must atomically rename a same-directory stage.'
Assert-TextPresent $setup 'function Remove-EmptyOwnedTransactionDirectories' 'Setup must track and clean only empty parent directories it created.'
Assert-TextPresent $sync '\[IO\.Directory\]::Move\(\$stage, \$snapshot\)' 'Snapshot sync must atomically rename its same-directory stage.'
Assert-TextPresent $sync 'Codex plugin manifest source' 'Snapshot sync must revalidate source fingerprints after staging.'
Assert-TextPresent $environmentHelpers 'function Get-StablePathState' 'Transaction backup checks need a stable path fingerprint helper.'
Assert-TextPresent $environmentHelpers 'function Write-MinicondaRuntimeConfig' 'Runtime config must use the bundled atomic writer.'
Assert-TextPresent $environmentHelpers 'function Get-MinicondaRuntimeConfigState' 'Runtime config reads must share the writer mutex and residue guard.'
Assert-TextPresent $environmentHelpers '\[IO\.File\]::Replace' 'Existing runtime config replacement must use an atomic same-directory operation.'
Assert-TextPresent $skill 'Write-MinicondaRuntimeConfig' 'SKILL.md must use the mutex-protected atomic runtime-config writer.'
Assert-TextPresent $skill '(?s)Get-ExecutionPolicy -Scope Process.*?Set-ExecutionPolicy -Scope Process.*?Bypass.*?finally.*?Set-ExecutionPolicy -Scope Process.*?\$priorProcessPolicy' 'Helper loading must use and then restore only the process execution policy.'
Assert-TextPresent $gitattributes '^\* text=auto eol=lf\s*$' 'Repository text files must have a deterministic LF policy.'
Assert-TextPresent $skill 'configure this skill''s environment roots' 'The trigger description must cover runtime-root configuration.'
Assert-TextPresent $skill 'changed or removed the config while waiting' 'Root changes must use observed-state conflict detection.'
Assert-TextAbsent $skill 'Edit the UTF-8 JSON config' 'SKILL.md must not recommend bypassing its atomic config writer.'
Assert-TextPresent $skill 'Get-Content -LiteralPath \$cfgPath -Raw -Encoding UTF8' 'Config reads must explicitly use UTF-8.'
Assert-TextPresent $skill '\$cfg = \$null' 'Config state must reset before checking for a missing file.'
foreach ($label in @('TEMP', 'STANDALONE', 'PROJECT')) {
    Assert-TextPresent $skill ("\*\*" + $label + "\*\*") "Lifecycle label $label is missing."
}
foreach ($origin in @('EXPLICIT', 'IMPLICIT')) {
    Assert-TextPresent $skill ("\*\*" + $origin + "\*\*") "Trigger origin $origin is missing."
}
Assert-TextAbsent $skill 'Scenario [ABC]|A/B/C' 'SKILL.md must not overload A/B/C scenarios.'
Assert-TextPresent $skill "EnvKind = 'conda'.*'venv'" 'SKILL.md must explicitly represent reused venv identity state.'
Assert-TextPresent $skill 'Get-ProjectPythonManager' 'Manager ownership must be detected before generic .venv/.conda reuse.'
Assert-TextPresent $skill 'Resolve-PythonProjectRoot' 'Project discovery must use the deterministic nearest-root resolver.'
Assert-TextPresent $environmentHelpers 'pyproject\.toml' 'Manager ownership must inspect pyproject.toml before generic env reuse.'
Assert-TextPresent $skill 'only when no manager owns it' 'Generic environment reuse must exclude manager-owned directories.'
Assert-TextPresent $skill 'Never issue `conda install`, `conda remove`, or `conda env export` for a venv' 'Reused venv guard is missing.'
Assert-TextPresent $skill 'Skip this section for a selected venv' 'A reused non-conda environment must skip Miniconda detection/installation.'
Assert-TextPresent $skill 'Reused conda/Anaconda env' 'Reused conda policy section is missing.'
Assert-TextPresent $skill 'Do \*\*not\*\* inject `conda-forge` or' 'Reused conda environments must preserve channels.'
Assert-TextPresent $skill 'CreatedThisInvocation' 'Cleanup ownership state is missing.'
Assert-TextPresent $skill '<six-random-hex>' 'TEMP paths must include a collision-resistant suffix.'
Assert-TextPresent $creationReference 'Environment path appeared while waiting for its prefix lock' 'Creation must recheck for concurrent path creation under the prefix mutex.'
Assert-TextPresent $creationReference 'finally' 'TEMP cleanup must be in finally.'
Assert-TextPresent $creationReference '(?s)finally\s*\{.*?Remove-OwnedTempCondaEnv\s+-TempEnvRoot\s+\$TempEnvRoot\s+-EnvPath\s+\$EnvPath.*?-EnvName\s+\$EnvName\s+-CondaExe\s+\$CondaExe\s+-Claim\s+\$CreationClaim' 'The executable TEMP finally example must pass every cleanup ownership argument, including the atomic claim.'
Assert-TextPresent $skill '\$EnvName = Split-Path -Leaf' 'The executable TEMP cleanup name must be initialized before the outer transaction.'
Assert-TextPresent $skill '(?s)\$ManagedRoot = if \(\$Lifecycle -eq ''PROJECT''\).*?\$EnvName' 'Every manifest and no-manifest creation branch must initialize ManagedRoot in shared state.'
Assert-TextPresent $environmentHelpers 'function Get-StableStandaloneEnvironmentPath' 'STANDALONE paths must derive from stable script identity.'
Assert-TextPresent $environmentHelpers 'function Write-StandaloneEnvironmentIdentity' 'STANDALONE finalization must retain durable script identity.'
Assert-TextPresent $environmentHelpers 'function Get-OwnedStandaloneEnvironment' 'STANDALONE reuse must validate durable script identity.'
Assert-TextPresent $environmentHelpers 'function New-CondaEnvironmentCreationApproval' 'No-manifest creation must produce a confirmable approval record.'
Assert-TextPresent $environmentHelpers 'function Assert-CondaEnvironmentCreationApproval' 'No-manifest creation must revalidate its approved record.'
Assert-TextPresent $creationReference '(?s)Assert-CondaEnvironmentCreationApproval.*?Invoke-CondaEnvironmentCreate' 'No-manifest approval must be checked under the prefix lock immediately before conda.'
Assert-TextPresent $creationReference '\$LockedCreationPlan\.PythonVersion' 'Conda argv must use the locked approved Python version.'
Assert-TextPresent $creationReference '(?s)Assert-CondaEnvironmentCreationApproval.*?New-ManagedEnvironmentClaim' 'No-manifest approval must be validated before reserving a prefix.'
Assert-TextPresent $creationReference '(?s)\$CreationAttempted = \$true\s+\$(?:null|createResult) = Invoke-Conda' 'CreationAttempted must be set only at the native creation boundary.'
Assert-TextPresent $skill '(?s)\$ManagedRoot = .*?Assert-ManagedEnvironmentCreationPath.*?New-CondaEnvironmentCreationApproval' 'ManagedRoot and the path guard must be established before no-manifest approval.'
Assert-TextPresent $skill "else \{ '3\.12' \}" 'A no-manifest plan must define a nonblank documented Python default.'
Assert-TextPresent $environmentHelpers 'function Invoke-WithManagedEnvironmentMarkerProtection' 'Every conda create path must restore an ownership marker removed by conda.'
Assert-TextPresent $environmentHelpers 'function Invoke-CondaEnvironmentCreate' 'No-manifest conda creation must use the marker-protected helper.'
Assert-TextPresent $environmentHelpers 'function Invoke-WithIsolatedCondaExecutionContext' 'No-manifest conda operations need a held minimal CONDARC.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-CondaEnvironmentCreate.*?Invoke-WithIsolatedCondaExecutionContext.*?--no-default-packages' 'No-manifest creation must exclude inherited config and default packages.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-CondaEnvironmentPackageInstall.*?Invoke-WithIsolatedCondaExecutionContext' 'New-environment conda dependency installs must share the isolated policy.'
Assert-TextPresent $environmentHelpers 'function Get-LockedCondaEnvironmentCreationPlan' 'Post-create dependency work must revalidate the complete approval record.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-CondaEnvironmentPackageInstall.*?ApprovedPlan.*?python=\$expectedPython.*?Assert-CondaEnvironmentPython' 'Conda dependency bootstrap must derive, constrain, and recheck the approved Python major.minor.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-PipEnvironmentPackageInstall.*?ApprovedPlan.*?locked\.PipPackages.*?Assert-CondaEnvironmentPython' 'Pip dependency bootstrap must derive path, packages, and Python from the locked approval.'
Assert-TextPresent $skill 'Invoke-CondaEnvironmentPackageInstall' 'SKILL.md must route new-environment conda bootstrap through the isolated helper.'
Assert-TextPresent $skill '(?s)LockedCreationPlan\.CondaPackages.*?Invoke-CondaEnvironmentPackageInstall.*?-ApprovedPlan \$LockedCreationPlan' 'SKILL.md must ignore ambient conda bootstrap variables after approval.'
Assert-TextPresent $skill '(?s)LockedCreationPlan\.PipPackages.*?Invoke-PipEnvironmentPackageInstall.*?-ApprovedPlan \$LockedCreationPlan' 'SKILL.md must ignore ambient pip bootstrap variables after approval.'
Assert-TextPresent $creationReference 'never ambient path/version/package variables' 'The executable creation boundary must preserve the locked plan through bootstrap.'
Assert-TextPresent $environmentHelpers 'function Assert-CondaProjectManifestHasNoExternalInstallers' 'PROJECT previews must inspect the held manifest itself for external installers.'
Assert-TextPresent $environmentHelpers 'YamlFileSpec' 'PROJECT manifest policy must use conda''s YAML parser rather than a regex.'
Assert-TextPresent $environmentHelpers 'direct interpreter execution does not activate conda environment variables' 'PROJECT manifests with conda activation variables must fail closed.'
Assert-TextPresent $environmentHelpers '(?s)function Get-CondaProjectPlanPreviewState.*?--environment-specifier'', ''environment\.yml''.*?--no-default-packages' 'PROJECT dry-run must force conda''s built-in environment.yml parser and exclude inherited default packages.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-CondaProjectEnvironmentCreate.*?--environment-specifier''.*?''environment\.yml''.*?--no-default-packages' 'PROJECT creation must use the same explicit built-in parser policy as preview.'
Assert-TextPresent $skill '(?s)project-\*'' -and \(\$CondaPackages -or \$PipPackages\).*?separate explicit approval' 'PROJECT creation must not silently append an unbound conda or pip package list after the approved solve.'
Assert-TextPresent $environmentHelpers 'CondaExe = \[IO\.Path\]::GetFullPath' 'PROJECT approval fingerprints must bind the conda executable.'
Assert-TextPresent $manifestReference 'Select-Object ManifestPath, EnvPath, CondaExe' 'PROJECT approval JSON must preserve the bound conda executable across turns.'
Assert-TextPresent $manifestReference '\$manifestState\.Kind -ceq ''File''' 'Manifest overwrite prompting must use the state object''s real Kind property.'
Assert-TextPresent $manifestReference '\$ManifestAction = ''Replace''' 'Absent/equivalent manifest writes need an executable default action.'
Assert-TextPresent $environmentHelpers 'function Test-MinicondaPythonEnvFaultInjectionEnabled' 'Production helpers must gate test-only fault injection.'
Assert-TextAbsent $creationReference 'Invoke-NativeChecked \{ & \$PythonExe \$ScriptPath \} ''Python task''\s*(?:#.*)?\r?\n\s*#' 'Task execution must not assume every Python request has ScriptPath.'
Assert-TextPresent $environmentHelpers '@\(''remove'', ''--prefix'', \$envFull, ''--all'', ''-y''' 'TEMP cleanup must be conda-aware.'
Assert-TextPresent $environmentHelpers '(?s)@\(''remove''.*?https://conda\.anaconda\.org/conda-forge''.*?''--override-channels'', ''--offline''' 'TEMP cleanup must not consult unrelated .condarc channels or ToS state.'
Assert-TextPresent $environmentHelpers '(?s)function Remove-OwnedManagedCondaEnv.*?Invoke-CondaProjectChild' 'TEMP cleanup must scrub child CI/ToS auto-accept state.'
Assert-TextPresent $environmentHelpers '(?s)function Remove-OwnedManagedCondaEnv.*?Assert-ManagedEnvironmentCreationPath' 'All owned cleanup must reapply the direct-child lifecycle guard.'
Assert-TextPresent $environmentHelpers 'ReparsePoint' 'TEMP cleanup must refuse reparse points.'
Assert-TextPresent $environmentHelpers 'function Assert-ManagedEnvironmentCreationPath' 'New environments need one executable lifecycle path guard.'
Assert-TextPresent $environmentHelpers 'function Enter-ManagedEnvironmentMutex' 'Each new canonical prefix needs a mutex.'
Assert-TextPresent $environmentHelpers 'FileMode\]::CreateNew' 'Environment ownership claims must use atomic create-new semantics.'
Assert-TextPresent $environmentHelpers 'function Resolve-ValidatedCondaExecutable' 'Conda candidates need an executable identity probe.'
Assert-TextPresent $environmentHelpers 'function Assert-CondaEnvironmentPython' 'A conda success code must be followed by an exact interpreter health check.'
Assert-TextPresent $environmentHelpers 'function Get-IsolatableProjectManifestChannels' 'PROJECT manifest isolation needs a fail-closed channel policy parser.'
Assert-TextPresent $environmentHelpers 'function Invoke-ProcessCapturedChecked' 'A temporary CONDARC must be scoped to the conda child process.'
Assert-TextAbsent $environmentHelpers '\$env:CONDARC\s*=' 'The helper must not mutate process-global CONDARC state.'
Assert-TextPresent $environmentHelpers 'function Get-CondaProjectEnvironmentPreview' 'PROJECT creation needs an executable dry-run preview.'
Assert-TextPresent $environmentHelpers '(?s)function Invoke-CondaProjectEnvironmentCreate.*?ApprovedPreview.*?ManifestFingerprint.*?PlanFingerprint' 'PROJECT creation must bind execution to the approved manifest and solve plan.'
Assert-TextPresent $manifestReference '(?s)Get-CondaProjectEnvironmentPreview.*?ResolvedSources.*?PackageCount.*?ManifestFingerprint.*?PlanFingerprint' 'The PROJECT reference must show the exact preview before approval.'
Assert-TextPresent $creationReference '-ApprovedPreview \$ProjectPreview' 'PROJECT creation must pass the approved preview into the execution recheck.'
Assert-TextPresent $creationReference 'Assert-ManagedEnvironmentCreationPath' 'Every creation transaction must repeat the lifecycle path guard under lock.'
Assert-TextPresent $environmentHelpers '\$envRelative = .*Replace\(' 'Nested PROJECT env paths must be relative to the actual Git root.'
Assert-TextPresent $environmentHelpers 'git -C \$gitRoot check-ignore --quiet -- \$probeRelative' 'PROJECT .conda must be effectively gitignored at its exact nested path.'
Assert-TextPresent $skill 'Protect-ProjectCondaGitIgnore' 'SKILL.md must route PROJECT ignore setup through the bundled transaction helper.'
Assert-TextPresent $environmentHelpers 'function Add-GitIgnoreRuleAtomic' '.gitignore updates must use the bundled atomic transaction helper.'
Assert-TextAbsent $skill 'AppendAllText' 'SKILL.md must not append directly to a concurrently editable .gitignore.'
Assert-TextPresent $environmentHelpers 'function Undo-GitIgnoreRuleAtomic' 'A failed PROJECT creation needs a compare-and-swap .gitignore rollback.'
Assert-TextPresent $manifestReference 'same isolated or explicitly approved inherited policy' 'PROJECT exports must use an isolated manifest policy or the exact approved inherited-policy preview.'
Assert-TextPresent $manifestReference 'audits installed package sources' 'PROJECT export documentation must require installed-source auditing.'
Assert-TextPresent $environmentHelpers 'Join-Path \$envFull ''python\.exe''' 'New conda creation must resolve the direct interpreter path.'
Assert-TextPresent $creationReference '(?s)try\s*\{.*?Enter-ManagedEnvironmentMutex.*?New-ManagedEnvironmentClaim.*?\$CreationAttempted = \$true.*?Assert-CondaEnvironmentPython.*?finally' 'Prefix reservation, creation, health checking, and cleanup must share one outer boundary.'
Assert-TextPresent $skill '\$env:CONDA_EXE' 'Conda detection must support PowerShell conda-init functions through CONDA_EXE.'
Assert-TextAbsent $skill 'Get-Command conda -ErrorAction SilentlyContinue\)\.Source' 'Conda detection must not rely on FunctionInfo.Source.'
Assert-TextPresent $skill 'Write-CondaEnvironmentManifestAtomic' 'Manifest overwrite guard must route through the atomic CAS writer.'
Assert-TextPresent $environmentHelpers 'function Invoke-CondaEnvironmentYamlExport' 'Conda exports need one policy-scoped helper.'
Assert-TextPresent $environmentHelpers '''env'', ''export'', ''--prefix'', \$envFull, ''--no-builds''' 'Conda export must omit platform-specific build pins.'
Assert-TextPresent $environmentHelpers 'function Invoke-NativeCaptured' 'Machine-readable native stdout needs a stream-separated capture helper.'
Assert-TextPresent $environmentHelpers '\$ErrorActionPreference = ''Continue''' 'Windows PowerShell 5.1 native stderr must not terminate before exit-code capture.'
Assert-TextAbsent $environmentHelpers '2>&1' 'Native helpers must not merge stderr into machine-readable stdout.'
Assert-TextPresent $environmentHelpers 'recognizable environment YAML' 'Export must validate its basic YAML structure before writing.'
Assert-TextPresent $environmentHelpers 'pip subsection whose package sources are not bound' 'Conda export must not emit a pip subsection that PROJECT restore rejects.'
Assert-TextPresent $environmentHelpers 'project-isolated.*project-inherited' 'Export must distinguish isolated and approved inherited PROJECT policies.'
Assert-TextPresent $environmentHelpers '(?s)project-isolated.*?--override-channels' 'Isolated PROJECT export must exclude user config channels.'
Assert-TextPresent $environmentHelpers 'function Remove-CondaYamlMachineMetadata' 'environment.yml export must remove scalar or wrapped prefix/name metadata.'
Assert-TextPresent $environmentHelpers 'function Write-CondaEnvironmentManifestAtomic' 'environment.yml writes must use the bundled atomic CAS writer.'
Assert-TextPresent $creationReference 'Cleanup also failed' 'TEMP task failures and cleanup failures must both be preserved.'
Assert-TextPresent $skill 'SHA-256' 'Miniconda install plan must require checksum verification.'
Assert-TextPresent $skill 'Authenticode' 'Miniconda install plan must address Authenticode.'
Assert-TextPresent $skill 'Never accept terms for the user' 'The skill must not auto-accept Anaconda channel terms.'
Assert-TextPresent $manifestReference '2025-07-15' 'The channel ToS plugin date must be precise.'
Assert-TextAbsent $skill '2024\+' 'Outdated ToS dating remains in SKILL.md.'

Write-Host '[4/7] Redirected-input guard, path safety, and setup mutex'
$setupLiteral = ConvertTo-PowerShellLiteral $setup
$guard = Invoke-RedirectedPowerShell "& $setupLiteral"
Assert-True ($guard.ExitCode -eq 1) 'setup.ps1 without parameters should exit 1 with redirected stdin.'
Assert-True ($guard.Output -match 'stdin is redirected/non-interactive') 'setup.ps1 guard must explain redirected stdin.'
$partial = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'D:\PyTemp' -Force"
Assert-True ($partial.ExitCode -eq 1) 'setup.ps1 with one required path should fail with redirected stdin.'
Assert-True ($partial.Output -match 'missing required path') 'Partial setup guard must identify missing paths.'
$relative = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'D:PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive"
Assert-True ($relative.ExitCode -eq 1) 'Drive-relative paths must be rejected.'
$injected = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'D:\PyTemp;Injected' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive"
Assert-True ($injected.ExitCode -eq 1) 'Semicolon-bearing managed paths must be rejected.'
$superscriptDevices = @()
foreach ($codePoint in @(0x00B9, 0x00B2, 0x00B3)) {
    $superscriptDevices += "C:\COM$([char]$codePoint)"
    $superscriptDevices += "C:\LPT$([char]$codePoint)"
}
foreach ($unsafePath in @('C:\CON', 'C:\bad.', 'C:\bad:stream', 'C:\bad?name', ' C:\leading') + $superscriptDevices) {
    $unsafeLiteral = ConvertTo-PowerShellLiteral $unsafePath
    $unsafe = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot $unsafeLiteral -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive"
    Assert-True ($unsafe.ExitCode -eq 1) "Unsafe Windows path must be rejected: $unsafePath"
}
$missingDriveRoot = $null
foreach ($code in 90..68) {
    $candidateDriveRoot = ([char]$code).ToString() + ':\'
    if (-not [IO.Directory]::Exists($candidateDriveRoot)) {
        $missingDriveRoot = $candidateDriveRoot
        break
    }
}
Assert-True (-not [string]::IsNullOrWhiteSpace($missingDriveRoot)) 'Could not find an unavailable drive letter for path validation.'
$missingDriveLiteral = ConvertTo-PowerShellLiteral ($missingDriveRoot + 'PyTemp')
$missingDrive = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot $missingDriveLiteral -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive"
Assert-True ($missingDrive.ExitCode -eq 1) 'A TempEnvRoot on an unavailable drive must be rejected.'
Assert-True ($missingDrive.Output -match 'not currently available') 'Unavailable-drive rejection should be actionable.'
Assert-TextPresent $setup 'agents\\openai\.yaml' 'setup.ps1 must preflight the complete skill payload.'
Assert-TextPresent $setup 'existing config is unusable and was not replaced' 'Invalid config may not be retained while skill installation continues.'
Assert-TextPresent $setup 'Unresolved setup transaction residue' 'Setup must fail closed on abandoned transaction residue.'

$lockHome = Join-Path ([IO.Path]::GetTempPath()) ('mini-lock-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$setupMutexName = 'Local\mini-setup-verify-' + [guid]::NewGuid().ToString('N')
$heldSetupMutex = New-Object Threading.Mutex($false, $setupMutexName)
$ownsSetupMutex = $heldSetupMutex.WaitOne(0)
try {
    Assert-True $ownsSetupMutex 'Test process could not acquire the setup mutex.'
    $setupLocked = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" @{
        USERPROFILE = $lockHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_NAME = $setupMutexName
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_TIMEOUT_SECONDS = '1'
    } 10
    Assert-True ($setupLocked.ExitCode -eq 1) 'A second setup process must time out while the user lock is held.'
    Assert-True ($setupLocked.Output -match 'Timed out waiting') 'Setup mutex timeout must be actionable.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $lockHome '.config'))) 'A timed-out setup process wrote user state.'
}
finally {
    if ($ownsSetupMutex) { $heldSetupMutex.ReleaseMutex() }
    $heldSetupMutex.Dispose()
}
try {
    $setupAfterRelease = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" @{
        USERPROFILE = $lockHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_NAME = $setupMutexName
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_TIMEOUT_SECONDS = '2'
    }
    Assert-True ($setupAfterRelease.ExitCode -eq 0) "Setup lock was not reusable after release: $($setupAfterRelease.Output)"
}
finally { Remove-TestTree $lockHome }

$abandonedHome = Join-Path ([IO.Path]::GetTempPath()) ('mini-abandoned-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$abandonedMutexName = 'Local\mini-setup-abandoned-' + [guid]::NewGuid().ToString('N')
$observerMutex = New-Object Threading.Mutex($false, $abandonedMutexName)
try {
    $abandon = Invoke-RedirectedPowerShell '$m = New-Object Threading.Mutex($false, $env:VERIFY_MUTEX); $null = $m.WaitOne(); [Environment]::Exit(17)' @{
        VERIFY_MUTEX = $abandonedMutexName
    }
    Assert-True ($abandon.ExitCode -eq 17) 'Abandoned-mutex owner did not terminate at the intended boundary.'
    $afterAbandon = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" @{
        USERPROFILE = $abandonedHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_NAME = $abandonedMutexName
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_TIMEOUT_SECONDS = '2'
    }
    Assert-True ($afterAbandon.ExitCode -eq 0) "Setup failed to recover an abandoned mutex: $($afterAbandon.Output)"
    Assert-True ($afterAbandon.Output -match 'Recovered abandoned setup lock') 'Abandoned setup mutex recovery must be explicit.'
}
finally {
    $observerMutex.Dispose()
    Remove-TestTree $abandonedHome
}

$disabledHookHome = Join-Path ([IO.Path]::GetTempPath()) (
    'mini-disabled-hook-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
try {
    $disabledHookSetup = Invoke-RedirectedPowerShell `
        "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" @{
            USERPROFILE = $disabledHookHome
            MINICONDA_PYTHON_ENV_TEST_MODE = ''
            MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_BEFORE_BACKUP_OPERATION = '1'
        }
    Assert-True ($disabledHookSetup.ExitCode -eq 0) `
        "A production setup honored an inherited test-only failure hook: $($disabledHookSetup.Output)"
}
finally { Remove-TestTree $disabledHookHome }

foreach ($runtimeResidueKind in @('stage', 'replace-backup')) {
    $runtimeResidueHome = Join-Path ([IO.Path]::GetTempPath()) (
        'mini-setup-runtime-residue-' + $runtimeResidueKind + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $runtimeConfigDirectory = Join-Path $runtimeResidueHome '.config\claude-skills'
        New-Item -ItemType Directory -Path $runtimeConfigDirectory -Force | Out-Null
        $runtimeResiduePath = Join-Path $runtimeConfigDirectory (
            '.miniconda-python-env.json.' + $runtimeResidueKind + '-' + ('a' * 32))
        [IO.File]::WriteAllText($runtimeResiduePath, 'manual recovery', (New-Object Text.UTF8Encoding($false)))
        $runtimeResidueSetup = Invoke-RedirectedPowerShell `
            "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" @{
                USERPROFILE = $runtimeResidueHome
            }
        Assert-True ($runtimeResidueSetup.ExitCode -eq 1) `
            "Setup accepted unresolved runtime-config $runtimeResidueKind residue: $($runtimeResidueSetup.Output)"
        Assert-True ($runtimeResidueSetup.Output -match 'runtime-config transaction residue') `
            "Setup did not diagnose runtime-config $runtimeResidueKind residue."
        Assert-True (Test-Path -LiteralPath $runtimeResiduePath -PathType Leaf) `
            "Setup removed runtime-config $runtimeResidueKind residue instead of preserving it."
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtimeResidueHome '.codex'))) `
            "Setup wrote an agent destination after detecting runtime-config $runtimeResidueKind residue."
    }
    finally { Remove-TestTree $runtimeResidueHome }
}

Write-Host '[5/7] Setup UTF-8, replacement, and transactional rollback'
$freshSetupHome = Join-Path ([IO.Path]::GetTempPath()) ('mini-fresh-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$freshStageBaseline = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
    Where-Object { $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' } |
    ForEach-Object { $_.FullName })
try {
    New-Item -ItemType Directory -Path $freshSetupHome -Force | Out-Null
    $freshEnvironment = @{ USERPROFILE = $freshSetupHome }
    $sourceSetupEnvironment = @{
        USERPROFILE = $freshSetupHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_MUTATE_SOURCE_DURING_STAGE = '1'
    }
    $sourceSetup = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" $sourceSetupEnvironment
    Assert-True ($sourceSetup.ExitCode -eq 1) 'Setup must reject a source mutation during staging.'
    Assert-True ($sourceSetup.Output -match 'Skill source during setup staging fingerprint changed') 'Setup did not report the staged-source race.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $freshSetupHome '.config'))) 'Source-race rejection wrote user config state.'
    Assert-True (@(Get-ChildItem -LiteralPath $skillRoot -Force |
        Where-Object { $_.Name -match '^\.setup-source-mutation-[0-9a-f]{32}$' }).Count -eq 0) 'Setup source-mutation hook left a marker in the source tree.'

    $parentFailureEnvironment = @{
        USERPROFILE = $freshSetupHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_BEFORE_BACKUP_OPERATION = '1'
    }
    $parentFailure = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\PyTemp' -ToolsRoot 'D:\Tools' -Agent codex -Force -NonInteractive" $parentFailureEnvironment
    Assert-True ($parentFailure.ExitCode -eq 1) 'Fresh setup parent-cleanup fault injection should exit 1.'
    Assert-True ($parentFailure.Output -match 'all committed changes were rolled back') 'Fresh setup parent-cleanup failure did not complete rollback.'
    foreach ($ownedRoot in @('.config', '.codex', '.claude')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $freshSetupHome $ownedRoot))) "Setup failure left newly-created parent tree $ownedRoot."
    }
    Assert-True (@(Get-ChildItem -LiteralPath $freshSetupHome -Recurse -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '\.setup-parent-[0-9a-f]{32}$' }).Count -eq 0) 'Setup failure left parent-directory staging residue.'
}
finally {
    Remove-TestTree $freshSetupHome
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
        Where-Object {
            $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' -and
            $_.FullName -notin $freshStageBaseline
        } | ForEach-Object { Remove-TestTree $_.FullName }
}

$testHome = Join-Path ([IO.Path]::GetTempPath()) ('mini-v-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$childEnv = @{ USERPROFILE = $testHome }
try {
    New-Item -ItemType Directory -Path $testHome -Force | Out-Null
    $first = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\' -ToolsRoot 'D:\' -Agent both -Force -NonInteractive" $childEnv
    Assert-True ($first.ExitCode -eq 0) "setup.ps1 root-path install failed: $($first.Output)"
    $cfgPath = Join-Path $testHome '.config\claude-skills\miniconda-python-env.json'
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($cfg.temp_env_root -eq 'C:\') 'setup.ps1 must preserve TempEnvRoot C:\.'
    Assert-True ($cfg.tools_root -eq 'D:\') 'setup.ps1 must preserve ToolsRoot D:\.'
    $claudeTarget = Join-Path $testHome '.claude\skills\miniconda-python-env'
    $codexTarget = Join-Path $testHome '.codex\skills\miniconda-python-env'
    Assert-True (Test-Path -LiteralPath (Join-Path $codexTarget 'agents\openai.yaml') -PathType Leaf) 'setup.ps1 must install complete skill metadata.'

    $fakeResidue = "$cfgPath.backup-$('a' * 32)"
    Set-Content -LiteralPath $fakeResidue -Value 'manual-recovery-required' -Encoding ASCII
    try {
        $residueRun = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\After' -ToolsRoot 'D:\After' -Agent both -Force -NonInteractive" $childEnv
        Assert-True ($residueRun.ExitCode -eq 1) 'Setup must fail closed when transaction residue exists.'
        Assert-True ($residueRun.Output -match 'manual recovery') 'Setup residue failure must explain recovery.'
    }
    finally { Remove-Item -LiteralPath $fakeResidue -Force }

    Set-Content -LiteralPath (Join-Path $codexTarget 'obsolete.txt') -Value 'stale' -Encoding ASCII
    $replace = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\' -ToolsRoot 'D:\' -Agent both -Force -NonInteractive" $childEnv
    Assert-True ($replace.ExitCode -eq 0) "setup.ps1 replacement failed: $($replace.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $codexTarget 'obsolete.txt'))) 'Whole-directory replacement must remove stale files.'

    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $toolsWord = ([string][char]0x5de5) + ([string][char]0x5177)
    $unicodeTemp = "D:\$toolsWord"
    $unicodeTools = "C:\$toolsWord"
    $unicodeJson = @{ temp_env_root = $unicodeTemp; tools_root = $unicodeTools } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($cfgPath, $unicodeJson, $utf8NoBom)
    $unicodeTempLiteral = ConvertTo-PowerShellLiteral $unicodeTemp
    $unicodeToolsLiteral = ConvertTo-PowerShellLiteral $unicodeTools
    $unicode = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot $unicodeTempLiteral -ToolsRoot $unicodeToolsLiteral -Agent both -Force -NonInteractive" $childEnv
    Assert-True ($unicode.ExitCode -eq 0) "BOM-less UTF-8 config replacement failed: $($unicode.Output)"
    Assert-True ($unicode.Output -match [regex]::Escape($unicodeTemp)) 'BOM-less UTF-8 config was not decoded correctly.'

    [IO.File]::WriteAllText($cfgPath, '{"temp_env_root":"D:\\Only"}', $utf8NoBom)
    $repair = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot $unicodeTempLiteral -ToolsRoot $unicodeToolsLiteral -Agent both -Force -NonInteractive" $childEnv
    Assert-True ($repair.ExitCode -eq 0) "Malformed config repair failed: $($repair.Output)"
    Assert-True ($repair.Output -match 'Existing config is invalid') 'Missing config properties must be detected before replacement.'

    Set-Content -LiteralPath (Join-Path $claudeTarget 'sentinel.txt') -Value 'claude-before' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $codexTarget 'sentinel.txt') -Value 'codex-before' -Encoding ASCII
    $beforeConfig = [IO.File]::ReadAllBytes($cfgPath)

    $beforeBackupEnv = @{
        USERPROFILE = $testHome
        MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_BEFORE_BACKUP_OPERATION = '1'
    }
    $beforeBackup = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\Never' -ToolsRoot 'D:\Never' -Agent both -Force -NonInteractive" $beforeBackupEnv
    Assert-True ($beforeBackup.ExitCode -eq 1) 'Injected pre-backup failure should exit 1.'
    Assert-True ($beforeBackup.Output -match 'rolled back') 'Pre-backup failure must report rollback.'
    Assert-True ([Convert]::ToBase64String($beforeConfig) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfgPath))) 'Pre-backup rollback must never delete or rewrite the original config.'
    Assert-True (Test-Path -LiteralPath (Join-Path $claudeTarget 'sentinel.txt') -PathType Leaf) 'Pre-backup rollback must preserve the Claude target.'
    Assert-True (Test-Path -LiteralPath (Join-Path $codexTarget 'sentinel.txt') -PathType Leaf) 'Pre-backup rollback must preserve the Codex target.'

    $rollbackEnv = @{ USERPROFILE = $testHome; MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_AFTER_FIRST_TARGET = '1' }
    $rollback = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\After' -ToolsRoot 'D:\After' -Agent both -Force -NonInteractive" $rollbackEnv
    Assert-True ($rollback.ExitCode -eq 1) 'Injected setup failure should exit 1.'
    Assert-True ($rollback.Output -match 'rolled back') 'Setup failure must report rollback.'
    $afterConfig = [IO.File]::ReadAllBytes($cfgPath)
    Assert-True ([Convert]::ToBase64String($beforeConfig) -ceq [Convert]::ToBase64String($afterConfig)) 'Rollback must restore config byte-for-byte.'
    Assert-True (Test-Path -LiteralPath (Join-Path $claudeTarget 'sentinel.txt') -PathType Leaf) 'Rollback must restore the first replaced target.'
    Assert-True (Test-Path -LiteralPath (Join-Path $codexTarget 'sentinel.txt') -PathType Leaf) 'Rollback must leave later targets unchanged.'
    $backupResidue = @(Get-ChildItem -LiteralPath $testHome -Recurse -Force | Where-Object { $_.Name -match '\.backup-[0-9a-f]{32}$' })
    Assert-True ($backupResidue.Count -eq 0) 'Successful rollback must not leave transaction backups.'

    $canonicalStageBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
        Where-Object { $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' } |
        ForEach-Object { $_.FullName })
    $canonicalSetupBackup = $null
    try {
        $canonicalSetupEnvironment = @{
            USERPROFILE = $testHome
            MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_OPERATION = '1'
            MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_MODE = 'content'
        }
        $canonicalSetup = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\Concurrent' -ToolsRoot 'D:\Concurrent' -Agent both -Force -NonInteractive" $canonicalSetupEnvironment
        Assert-True ($canonicalSetup.ExitCode -eq 1) 'A concurrently-mutated setup canonical must fail closed.'
        Assert-True ($canonicalSetup.Output -match '(?s)Transaction canonical path.*fingerprint changed') 'Setup canonical mutation did not report an ownership mismatch.'
        Assert-True (Test-Path -LiteralPath $cfgPath -PathType Leaf) 'Setup canonical ownership failure deleted the externally-mutated config.'
        Assert-True ([Convert]::ToBase64String($beforeConfig) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfgPath))) 'Setup canonical mutation hook did not alter the preserved canonical config.'
        $canonicalSetupBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $cfgPath) -Force |
            Where-Object { $_.Name -match '^miniconda-python-env\.json\.backup-[0-9a-f]{32}$' })
        Assert-True ($canonicalSetupBackups.Count -eq 1) 'Setup canonical ownership failure did not preserve exactly one config backup.'
        $canonicalSetupBackup = $canonicalSetupBackups[0]
        Assert-True ([Convert]::ToBase64String($beforeConfig) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($canonicalSetupBackup.FullName))) 'Setup canonical ownership failure changed the rollback backup.'
        $canonicalStages = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
            Where-Object {
                $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' -and
                $_.FullName -notin $canonicalStageBefore
            })
        Assert-True ($canonicalStages.Count -eq 1) 'Setup canonical ownership failure did not preserve its recovery source stage.'
    }
    finally {
        if ($canonicalSetupBackup -and (Test-Path -LiteralPath $canonicalSetupBackup.FullName -PathType Leaf)) {
            Remove-TestTree $cfgPath
            [IO.File]::Move($canonicalSetupBackup.FullName, $cfgPath)
        }
        Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
            Where-Object {
                $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' -and
                $_.FullName -notin $canonicalStageBefore
            } | ForEach-Object { Remove-TestTree $_.FullName }
    }
    Assert-True ([Convert]::ToBase64String($beforeConfig) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfgPath))) 'Canonical ownership test did not restore its isolated config fixture.'

    $existing = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\After' -ToolsRoot 'D:\After' -Agent both -NonInteractive" $childEnv
    Assert-True ($existing.ExitCode -eq 1) 'Non-interactive overwrite without -Force must fail.'
    Assert-True ($existing.Output -match 'Re-run with -Force') 'Non-interactive overwrite failure must be actionable.'
    Assert-True ($existing.Output -notmatch 'Install complete') 'A refused overwrite must not claim installation completed.'

    $stageBeforeMismatch = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
        Where-Object { $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' } |
        ForEach-Object { $_.FullName })
    try {
        $mismatchEnv = @{
            USERPROFILE = $testHome
            MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_AFTER_FIRST_TARGET = '1'
            MINICONDA_PYTHON_ENV_SETUP_TEST_MUTATE_BACKUP_BEFORE_ROLLBACK = '1'
        }
        $mismatch = Invoke-RedirectedPowerShell "& $setupLiteral -TempEnvRoot 'C:\Fingerprint' -ToolsRoot 'D:\Fingerprint' -Agent both -Force -NonInteractive" $mismatchEnv
        Assert-True ($mismatch.ExitCode -eq 1) 'A fingerprint-mutated setup backup must fail closed.'
        Assert-True ($mismatch.Output -match 'fingerprint changed') 'Setup rollback did not report the backup fingerprint mismatch.'
        Assert-True ($mismatch.Output -match 'Staged recovery copy was preserved') 'Setup did not report its preserved staging recovery copy.'
        Assert-True (Test-Path -LiteralPath $cfgPath -PathType Leaf) 'Backup mismatch deleted the current runtime config.'
        Assert-True (Test-Path -LiteralPath (Join-Path $claudeTarget 'SKILL.md') -PathType Leaf) 'Backup mismatch deleted the current Claude skill copy.'
        $stageAfterMismatch = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
            Where-Object {
                $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' -and
                $_.FullName -notin $stageBeforeMismatch
            })
        Assert-True ($stageAfterMismatch.Count -eq 1) 'Setup fingerprint mismatch did not preserve exactly one staging tree.'
    }
    finally {
        Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
            Where-Object {
                $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' -and
                $_.FullName -notin $stageBeforeMismatch
            } | ForEach-Object { Remove-TestTree $_.FullName }
    }
}
finally { Remove-TestTree $testHome }

Write-Host '[6/7] Executable SKILL.md boundary examples'
$skillText = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
$helperLiteral = ConvertTo-PowerShellLiteral $environmentHelpers
$bootstrapCommand = ('$before=[string](Get-ExecutionPolicy -Scope Process); ' +
    '$priorProcessPolicy=Get-ExecutionPolicy -Scope Process; ' +
    '$changedProcessPolicy=$priorProcessPolicy -cne ''Bypass''; try {' +
    'if($changedProcessPolicy){Set-ExecutionPolicy -Scope Process Bypass -Force -ErrorAction Stop}; ' +
    '. ' + $helperLiteral +
    '} finally {if($changedProcessPolicy){Set-ExecutionPolicy -Scope Process $priorProcessPolicy -Force -ErrorAction Stop}}; ' +
    '$after=[string](Get-ExecutionPolicy -Scope Process); ' +
    '$loaded=[bool](Get-Command Get-MinicondaRuntimeConfigState -ErrorAction SilentlyContinue); ' +
    '[Console]::Out.Write("$before|$after|$loaded")')
foreach ($policyCase in @(
    @{ Policy = 'Restricted'; Expected = 'Restricted|Restricted|True' },
    @{ Policy = 'Default'; Expected = 'Undefined|Undefined|True' }
)) {
    $bootstrapResult = Invoke-RedirectedPowerShell $bootstrapCommand `
        -ExecutionPolicy $policyCase.Policy
    Assert-True ($bootstrapResult.ExitCode -eq 0 -and
        $bootstrapResult.StdOut.Trim() -ceq $policyCase.Expected) `
        "$($policyCase.Policy) helper bootstrap failed or leaked process policy: $($bootstrapResult.Output)"
}
. $environmentHelpers
$helperDeviceRejected = $false
try { $null = Resolve-ConfiguredPath ("C:\COM$([char]0x00B9)") 'test_root' }
catch { $helperDeviceRejected = $_.Exception.Message -match 'reserved Windows device' }
Assert-True $helperDeviceRejected 'Runtime path validation accepted a superscript-digit DOS device alias.'

$condarcResidueBaseline = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
    Where-Object { $_.Name -match '^miniconda-python-env-condarc-[0-9a-f]{32}\.yml$' } |
    ForEach-Object { $_.FullName })
$oldCondarcSubstitutionHook = $env:MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD
try {
    $env:MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD = '1'
    $condarcSubstitutionRejected = $false
    try { $null = New-IsolatedCondaExecutionContext }
    catch { $condarcSubstitutionRejected = $_.Exception.Message -match 'file identity changed' }
    Assert-True $condarcSubstitutionRejected 'A same-byte CONDARC substitution between create and hold was accepted.'
}
finally {
    if ($null -eq $oldCondarcSubstitutionHook) {
        Remove-Item Env:\MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD -ErrorAction SilentlyContinue
    } else {
        $env:MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD = $oldCondarcSubstitutionHook
    }
}
$condarcSubstitutionResidue = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force |
    Where-Object {
        $_.Name -match '^miniconda-python-env-condarc-[0-9a-f]{32}\.yml$' -and
        $_.FullName -notin $condarcResidueBaseline
    })
try {
    Assert-True ($condarcSubstitutionResidue.Count -eq 1) 'CONDARC substitution test did not preserve exactly the unowned replacement.'
}
finally {
    $condarcSubstitutionResidue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

$reparseCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-reparse-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$reparseTarget = Join-Path $reparseCase 'physical'
$reparseLink = Join-Path $reparseCase 'configured-root'
try {
    New-Item -ItemType Directory -Path $reparseTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $reparseLink -Target $reparseTarget | Out-Null
    foreach ($case in @(
        @{ Lifecycle = 'TEMP'; Leaf = 'task-20260713-010203-a1b2c3' },
        @{ Lifecycle = 'STANDALONE'; Leaf = 'task-20260713' },
        @{ Lifecycle = 'PROJECT'; Leaf = '.conda' }
    )) {
        $reparseRejected = $false
        try {
            Assert-ManagedEnvironmentCreationPath -Lifecycle $case.Lifecycle `
                -ManagedRoot $reparseLink -EnvPath (Join-Path $reparseLink $case.Leaf)
        }
        catch { $reparseRejected = $_.Exception.Message -match 'reparse point' }
        Assert-True $reparseRejected "The creation guard accepted a $($case.Lifecycle) root junction."
    }

    Assert-ManagedEnvironmentCreationPath -Lifecycle TEMP -ManagedRoot $reparseTarget `
        -EnvPath (Join-Path $reparseTarget 'task-20260713-010203-a1b2c3')
    $projectPercentRoot = Join-Path $reparseCase 'project%literal'
    New-Item -ItemType Directory -Path $projectPercentRoot -Force | Out-Null
    Assert-ManagedEnvironmentCreationPath -Lifecycle PROJECT -ManagedRoot $projectPercentRoot `
        -EnvPath (Join-Path $projectPercentRoot '.conda')
    $driveRoot = [IO.Path]::GetPathRoot($reparseCase)
    Assert-ManagedEnvironmentCreationPath -Lifecycle TEMP -ManagedRoot $driveRoot `
        -EnvPath (Join-Path $driveRoot ('mini-root-probe-' + [guid]::NewGuid().ToString('N')))
    $nestedRejected = $false
    try {
        Assert-ManagedEnvironmentCreationPath -Lifecycle STANDALONE -ManagedRoot $reparseTarget `
            -EnvPath (Join-Path $reparseTarget 'nested\task-20260713')
    }
    catch { $nestedRejected = $_.Exception.Message -match 'direct child' }
    Assert-True $nestedRejected 'The creation guard accepted a nested STANDALONE path outside the direct-child contract.'

    $projectLeafRejected = $false
    try {
        Assert-ManagedEnvironmentCreationPath -Lifecycle PROJECT -ManagedRoot $reparseTarget `
            -EnvPath (Join-Path $reparseTarget 'not-conda')
    }
    catch { $projectLeafRejected = $_.Exception.Message -match 'exact \.conda child' }
    Assert-True $projectLeafRejected 'The creation guard accepted a PROJECT environment other than the exact .conda child.'
}
finally {
    if (Test-Path -LiteralPath $reparseLink) { Remove-Item -LiteralPath $reparseLink -Force }
    Remove-TestTree $reparseCase
}

$configCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $atomicPath = Join-Path $configCase 'atomic\miniconda-python-env.json'
    $bomPath = Join-Path $configCase 'bom\miniconda-python-env.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $bomPath) -Force | Out-Null
    $bomJson = '{"temp_env_root":"C:\\Legacy","tools_root":"D:\\Tools"}'
    $bomPayload = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($bomJson)
    $bomBytes = New-Object byte[] ($bomPayload.Length + 3)
    $bomBytes[0] = 0xEF; $bomBytes[1] = 0xBB; $bomBytes[2] = 0xBF
    [Array]::Copy($bomPayload, 0, $bomBytes, 3, $bomPayload.Length)
    [IO.File]::WriteAllBytes($bomPath, $bomBytes)
    $bomState = Get-MinicondaRuntimeConfigState $bomPath
    $bomParsed = $bomState.Content | ConvertFrom-Json
    Assert-True ($bomState.Content[0] -ceq '{' -and $bomParsed.temp_env_root -ceq 'C:\Legacy') 'Runtime config did not remove exactly one leading UTF-8 BOM before JSON parsing.'
    Assert-True ($bomState.Fingerprint -ceq (ConvertTo-Sha256Hex $bomBytes)) 'Runtime config fingerprint did not bind the original BOM-containing bytes.'
    $invalidUtf8Path = Join-Path $configCase 'bom\invalid.json'
    [IO.File]::WriteAllBytes($invalidUtf8Path, [byte[]](0xC3, 0x28))
    $invalidUtf8Rejected = $false
    try { $null = Get-MinicondaRuntimeConfigState $invalidUtf8Path }
    catch { $invalidUtf8Rejected = $true }
    Assert-True $invalidUtf8Rejected 'BOM compatibility weakened strict UTF-8 validation.'

    $initialState = Get-MinicondaRuntimeConfigState $atomicPath
    $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
        -TempEnvRoot 'C:\Initial' -ToolsRoot 'D:\Initial' -ExpectedState $initialState
    $initialBytes = [IO.File]::ReadAllBytes($atomicPath)
    $replaceState = Get-MinicondaRuntimeConfigState $atomicPath
    $atomicFailure = $false
    try {
        $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_FAIL_BEFORE_REPLACE = '1'
        $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
            -TempEnvRoot 'C:\Replacement' -ToolsRoot 'D:\Replacement' -ExpectedState $replaceState
    }
    catch { $atomicFailure = $_.Exception.Message -match 'Simulated runtime-config failure' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_CONFIG_TEST_FAIL_BEFORE_REPLACE -ErrorAction SilentlyContinue }
    Assert-True $atomicFailure 'Injected runtime-config replacement failure did not reach the atomic boundary.'
    Assert-True ([Convert]::ToBase64String($initialBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($atomicPath))) 'Failed atomic replacement changed the prior config bytes.'
    $atomicParsed = Get-Content -LiteralPath $atomicPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($atomicParsed.temp_env_root -ceq 'C:\Initial' -and $atomicParsed.tools_root -ceq 'D:\Initial') 'Failed atomic replacement left malformed or mixed config.'
    $atomicResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $atomicPath) -Force |
        Where-Object { $_.Name -match '^\.miniconda-python-env\.json\.(stage|replace-backup)-[0-9a-f]{32}$' })
    Assert-True ($atomicResidue.Count -eq 0) 'Failed atomic replacement left staging residue.'

    $beforeReplaceState = Get-MinicondaRuntimeConfigState $atomicPath
    $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_BEFORE_REPLACE = '1'
    $beforeReplaceConflict = $false
    try {
        $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
            -TempEnvRoot 'C:\SkillBefore' -ToolsRoot 'D:\SkillBefore' -ExpectedState $beforeReplaceState
    }
    catch { $beforeReplaceConflict = $_.Exception.Message -match 'changed concurrently' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_BEFORE_REPLACE -ErrorAction SilentlyContinue }
    Assert-True $beforeReplaceConflict 'Runtime-config writer missed an external pre-replacement mutation.'
    $externalBefore = Get-Content -LiteralPath $atomicPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($externalBefore.temp_env_root -ceq 'C:\External') 'External pre-replacement runtime config was overwritten.'

    $externalBeforeState = Get-MinicondaRuntimeConfigState $atomicPath
    $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
        -TempEnvRoot 'C:\Initial' -ToolsRoot 'D:\Initial' -ExpectedState $externalBeforeState
    $atReplaceState = Get-MinicondaRuntimeConfigState $atomicPath
    $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_AT_REPLACE = '1'
    $atReplaceConflict = $false
    try {
        $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
            -TempEnvRoot 'C:\SkillAt' -ToolsRoot 'D:\SkillAt' -ExpectedState $atReplaceState
    }
    catch { $atReplaceConflict = $_.Exception.Message -match 'external bytes were restored' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_AT_REPLACE -ErrorAction SilentlyContinue }
    Assert-True $atReplaceConflict 'Runtime-config writer missed an external final-window mutation.'
    $externalAt = Get-Content -LiteralPath $atomicPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($externalAt.temp_env_root -ceq 'C:\AtReplace') 'Final-window runtime-config writer was not restored.'
    $atomicResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $atomicPath) -Force |
        Where-Object { $_.Name -match '^\.miniconda-python-env\.json\.(stage|replace-backup)-[0-9a-f]{32}$' })
    Assert-True ($atomicResidue.Count -eq 0) 'Runtime-config conflict tests left transaction residue.'

    [IO.File]::WriteAllText($atomicPath, '{"temp_env_root":', (New-Object Text.UTF8Encoding($false)))
    $malformedState = Get-MinicondaRuntimeConfigState $atomicPath
    $null = Write-MinicondaRuntimeConfig -Path $atomicPath `
        -TempEnvRoot 'C:\Repaired' -ToolsRoot 'D:\Repaired' -ExpectedState $malformedState
    $repaired = Get-Content -LiteralPath $atomicPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($repaired.temp_env_root -ceq 'C:\Repaired' -and $repaired.tools_root -ceq 'D:\Repaired') 'Authorized malformed config repair was not complete and valid.'

    $setupResidue = "$atomicPath.backup-$('b' * 32)"
    [IO.File]::WriteAllText($setupResidue, 'manual recovery', (New-Object Text.UTF8Encoding($false)))
    try {
        $residueRejected = $false
        try { $null = Get-MinicondaRuntimeConfigState $atomicPath }
        catch { $residueRejected = $_.Exception.Message -match 'manual recovery' }
        Assert-True $residueRejected 'Runtime config read ignored unresolved setup transaction residue.'
    }
    finally { Remove-Item -LiteralPath $setupResidue -Force }

    $setupStagingResidue = "$atomicPath.staging-$('c' * 32)"
    [IO.File]::WriteAllText($setupStagingResidue, 'manual recovery', (New-Object Text.UTF8Encoding($false)))
    try {
        $stagingResidueRejected = $false
        try { $null = Get-MinicondaRuntimeConfigState $atomicPath }
        catch { $stagingResidueRejected = $_.Exception.Message -match 'manual recovery' }
        Assert-True $stagingResidueRejected 'Runtime config read ignored unresolved setup staging residue.'
    }
    finally { Remove-Item -LiteralPath $setupStagingResidue -Force }

    $concurrentPath = Join-Path $configCase 'concurrent\miniconda-python-env.json'
    $readyA = Join-Path $configCase 'writer-a.ready'
    $readyB = Join-Path $configCase 'writer-b.ready'
    $go = Join-Path $configCase 'writers.go'
    $helperLiteral = ConvertTo-PowerShellLiteral $environmentHelpers
    $configLiteral = ConvertTo-PowerShellLiteral $concurrentPath
    $goLiteral = ConvertTo-PowerShellLiteral $go
    $commandA = '. ' + $helperLiteral + '; $path=' + $configLiteral +
        '; $state=Get-MinicondaRuntimeConfigState $path; [IO.File]::WriteAllText(' + (ConvertTo-PowerShellLiteral $readyA) +
        ',''ready''); $deadline=[DateTime]::UtcNow.AddSeconds(15); while(-not (Test-Path -LiteralPath ' + $goLiteral +
        ')){if([DateTime]::UtcNow -gt $deadline){throw ''go timeout''}; Start-Sleep -Milliseconds 25}; ' +
        '$null=Write-MinicondaRuntimeConfig -Path $path -TempEnvRoot ''C:\WriterA'' -ToolsRoot ''D:\WriterA'' -ExpectedState $state; ''WRITE_OK_A'''
    $commandB = '. ' + $helperLiteral + '; $path=' + $configLiteral +
        '; $state=Get-MinicondaRuntimeConfigState $path; [IO.File]::WriteAllText(' + (ConvertTo-PowerShellLiteral $readyB) +
        ',''ready''); $deadline=[DateTime]::UtcNow.AddSeconds(15); while(-not (Test-Path -LiteralPath ' + $goLiteral +
        ')){if([DateTime]::UtcNow -gt $deadline){throw ''go timeout''}; Start-Sleep -Milliseconds 25}; ' +
        '$null=Write-MinicondaRuntimeConfig -Path $path -TempEnvRoot ''C:\WriterB'' -ToolsRoot ''D:\WriterB'' -ExpectedState $state; ''WRITE_OK_B'''
    $writerA = Start-RedirectedPowerShell $commandA
    $writerB = Start-RedirectedPowerShell $commandB
    try {
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        while ((-not (Test-Path -LiteralPath $readyA) -or -not (Test-Path -LiteralPath $readyB)) -and
            [DateTime]::UtcNow -lt $readyDeadline) {
            Start-Sleep -Milliseconds 25
        }
        Assert-True ((Test-Path -LiteralPath $readyA) -and (Test-Path -LiteralPath $readyB)) 'Concurrent config writers did not both observe the initial absent state.'
        [IO.File]::WriteAllText($go, 'go')
        $writerAResult = Complete-RedirectedPowerShell $writerA 30
        $writerA = $null
        $writerBResult = Complete-RedirectedPowerShell $writerB 30
        $writerB = $null
        $writerResults = @($writerAResult, $writerBResult)
        $writerSummary = $writerResults | Select-Object ExitCode, StdOut, StdErr | ConvertTo-Json -Compress
        Assert-True (@($writerResults | Where-Object { $_.ExitCode -eq 0 }).Count -eq 1) "Exactly one conflicting runtime-config writer must win. Results: $writerSummary"
        Assert-True (@($writerResults | Where-Object { $_.Output -match 'changed concurrently' }).Count -eq 1) 'The losing runtime-config writer did not report a deterministic conflict.'
        $concurrentConfig = Get-Content -LiteralPath $concurrentPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $winnerPair = "$($concurrentConfig.temp_env_root)|$($concurrentConfig.tools_root)"
        Assert-True ($winnerPair -in @('C:\WriterA|D:\WriterA', 'C:\WriterB|D:\WriterB')) 'Concurrent writers left a mixed or malformed config.'
        $concurrentResidue = @(Get-ChildItem -LiteralPath (Split-Path -Parent $concurrentPath) -Force |
            Where-Object { $_.Name -match '^\.miniconda-python-env\.json\.(stage|replace-backup)-[0-9a-f]{32}$' })
        Assert-True ($concurrentResidue.Count -eq 0) 'Concurrent runtime-config writers left staging residue.'
    }
    finally {
        if (-not (Test-Path -LiteralPath $go)) { [IO.File]::WriteAllText($go, 'go') }
        foreach ($handle in @($writerA, $writerB) | Where-Object { $_ }) {
            try { $null = Complete-RedirectedPowerShell $handle 5 } catch {}
        }
    }
}
finally { Remove-TestTree $configCase }

$managerCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-manager-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    foreach ($fixture in @(
        @{ Name = 'uv'; Lock = 'uv.lock'; Env = '.venv\Scripts\python.exe' },
        @{ Name = 'poetry'; Lock = 'poetry.lock'; Env = '.venv\Scripts\python.exe' },
        @{ Name = 'pixi'; Lock = 'pixi.lock'; Env = '.pixi\envs\default\python.exe' },
        @{ Name = 'conda-lock'; Lock = 'conda-lock.yml'; Env = '.conda\python.exe' }
    )) {
        $project = Join-Path $managerCase $fixture.Name
        New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $project $fixture.Env)) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project $fixture.Env) -Value 'fixture' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $project $fixture.Lock) -Value 'fixture' -Encoding ASCII
        $owner = Get-ProjectPythonManager $project
        Assert-True ($owner -ceq $fixture.Name) "$($fixture.Name) manager ownership was lost to a generic environment directory."
    }
    foreach ($fixture in @(
        @{ Name = 'uv-pyproject'; Owner = 'uv'; Content = "[tool.uv]`nmanaged = true" },
        @{ Name = 'poetry-pyproject'; Owner = 'poetry'; Content = "[tool.poetry]`npackage-mode = false" },
        @{ Name = 'pdm-pyproject'; Owner = 'pdm'; Content = "[tool.pdm]`ndistribution = true" },
        @{ Name = 'pixi-pyproject'; Owner = 'pixi'; Content = "[tool.pixi.project]`nname = `"fixture`"" },
        @{ Name = 'hatch-pyproject'; Owner = 'hatch'; Content = "[tool.hatch.envs.default]`npython = `"3.12`"" },
        @{ Name = 'rye-pyproject'; Owner = 'rye'; Content = "[tool.rye]`nmanaged = true" }
    )) {
        $project = Join-Path $managerCase $fixture.Name
        New-Item -ItemType Directory -Path (Join-Path $project '.venv\Scripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project '.venv\Scripts\python.exe') -Value 'fixture' -Encoding ASCII
        [IO.File]::WriteAllText((Join-Path $project 'pyproject.toml'), $fixture.Content, (New-Object Text.UTF8Encoding($false)))
        $owner = Get-ProjectPythonManager $project
        Assert-True ($owner -ceq $fixture.Owner) "$($fixture.Owner) pyproject ownership was lost to a generic environment directory."
    }
    $duplicate = Join-Path $managerCase 'duplicate-same-manager'
    New-Item -ItemType Directory -Path $duplicate -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duplicate 'uv.lock') -Value 'fixture' -Encoding ASCII
    [IO.File]::WriteAllText((Join-Path $duplicate 'pyproject.toml'), "[tool.uv]`nmanaged = true", (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-ProjectPythonManager $duplicate) -ceq 'uv') 'Duplicate uv lock/pyproject signals were misclassified as conflicting managers.'
    $uvWithHatchling = Join-Path $managerCase 'uv-with-hatchling-backend'
    New-Item -ItemType Directory -Path $uvWithHatchling -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uvWithHatchling 'uv.lock') -Value 'fixture' -Encoding ASCII
    [IO.File]::WriteAllText((Join-Path $uvWithHatchling 'pyproject.toml'),
        "[build-system]`nbuild-backend = `"hatchling.build`"", (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Get-ProjectPythonManager $uvWithHatchling) -ceq 'uv') 'A Hatchling build backend was misclassified as an environment manager over uv.lock.'
    $backendOnly = Join-Path $managerCase 'backend-only'
    New-Item -ItemType Directory -Path $backendOnly -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $backendOnly 'pyproject.toml'),
        "[build-system]`nbuild-backend = `"hatchling.build`"", (New-Object Text.UTF8Encoding($false)))
    Assert-True ($null -eq (Get-ProjectPythonManager $backendOnly)) 'A build backend alone was treated as an environment manager.'
    $conflict = Join-Path $managerCase 'conflict'
    New-Item -ItemType Directory -Path $conflict -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $conflict 'uv.lock') -Value 'fixture' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $conflict 'poetry.lock') -Value 'fixture' -Encoding ASCII
    $conflictRejected = $false
    try { $null = Get-ProjectPythonManager $conflict }
    catch { $conflictRejected = $_.Exception.Message -match 'Conflicting Python manager signals' }
    Assert-True $conflictRejected 'Conflicting manager ownership signals must stop instead of choosing arbitrarily.'

    $outer = Join-Path $managerCase 'outer'
    $independent = Join-Path $outer '100% repo; [x]'
    $nearest = Join-Path $independent 'packages\nearest'
    $deep = Join-Path $nearest 'src'
    New-Item -ItemType Directory -Path $deep,(Join-Path $independent '.git') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $outer 'pyproject.toml'), '[project]', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Resolve-PythonProjectRoot $deep) -ieq $independent) 'Project-root discovery crossed the nearest independent Git boundary into an outer monorepo.'
    [IO.File]::WriteAllText((Join-Path $nearest 'requirements.txt'), 'fixture', (New-Object Text.UTF8Encoding($false)))
    Assert-True ((Resolve-PythonProjectRoot $deep) -ieq $nearest) 'Project-root discovery did not choose the nearest Python manifest in a special-character path.'
}
finally {
    Remove-TestTree $managerCase
    Remove-Item Function:\Get-ProjectPythonManager -ErrorAction SilentlyContinue
    Remove-Item Function:\Resolve-PythonProjectRoot -ErrorAction SilentlyContinue
}

$nativePayload = "[Console]::Out.WriteLine('dependencies:');[Console]::Out.WriteLine('  - python=3.12');[Console]::Error.WriteLine('warning-only');exit 0"
$nativeEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nativePayload))
$nativeWarnings = @()
$nativeStdout = Invoke-NativeChecked {
    & powershell.exe -NoProfile -EncodedCommand $nativeEncoded
} 'exit-zero stderr fixture' -WarningVariable nativeWarnings
Assert-True ($nativeStdout -match '(?m)^dependencies:\r?$') 'Native stdout was not captured from an exit-zero command.'
Assert-True ($nativeStdout -notmatch 'warning-only') 'Native stderr contaminated machine-readable stdout.'
Assert-True (($nativeWarnings -join "`n") -match 'warning-only') 'Exit-zero native stderr should be surfaced as a warning.'

$probeCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-nongit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path $probeCase -Force | Out-Null
    $expectedFailure = Invoke-NativeCaptured {
        & git -C $probeCase rev-parse --show-toplevel
    } 'expected non-git probe'
    Assert-True ($expectedFailure.ExitCode -ne 0) 'A non-Git probe unexpectedly succeeded.'
    Assert-True (($expectedFailure.StdOut + "`n" + $expectedFailure.StdErr) -match 'not a git repository') 'Expected non-Git stderr was not captured without terminating PowerShell 5.1.'
}
finally { Remove-TestTree $probeCase }

$gitCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-git-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $ProjectRoot = Join-Path $gitCase 'packages\a [x] !#'
    $EnvPath = Join-Path $ProjectRoot '.conda'
    New-Item -ItemType Directory -Path $ProjectRoot -Force | Out-Null
    $null = Invoke-NativeChecked { git -C $gitCase init --quiet } 'git init'
    $gitignorePath = Join-Path $gitCase '.gitignore'
    $bodyBytes = (New-Object Text.UTF8Encoding($false)).GetBytes("node_modules`r`n")
    $originalIgnoreBytes = New-Object byte[] ($bodyBytes.Length + 3)
    $originalIgnoreBytes[0] = 0xEF; $originalIgnoreBytes[1] = 0xBB; $originalIgnoreBytes[2] = 0xBF
    [Array]::Copy($bodyBytes, 0, $originalIgnoreBytes, 3, $bodyBytes.Length)
    [IO.File]::WriteAllBytes($gitignorePath, $originalIgnoreBytes)
    $gitTransaction = Protect-ProjectCondaGitIgnore -ProjectRoot $ProjectRoot -EnvPath $EnvPath
    Assert-True ($null -ne $gitTransaction) 'PROJECT helper did not return a transaction for a newly added ignore rule.'
    $ignoreBytes = [IO.File]::ReadAllBytes($gitignorePath)
    $ignoreText = (New-Object Text.UTF8Encoding($false, $true)).GetString($ignoreBytes)
    $expectedLiteralRule = ConvertTo-GitIgnoreLiteralPattern -RelativePath 'packages/a [x] !#/.conda'
    Assert-True (@($ignoreText -split '\r?\n') -ccontains $expectedLiteralRule) 'Special PROJECT path was not encoded as one literal, anchored Git pattern.'
    & git -C $gitCase check-ignore --quiet -- 'packages/a [x] !#/.conda/__skill_probe__'
    Assert-True ($LASTEXITCODE -eq 0) 'The exact nested PROJECT env probe is not effectively ignored.'
    Assert-True ($ignoreBytes[0] -eq 0xEF -and $ignoreBytes[1] -eq 0xBB -and $ignoreBytes[2] -eq 0xBF) '.gitignore transaction did not preserve the existing UTF-8 BOM.'
    Assert-True ($ignoreText -match "node_modules`r`n") '.gitignore transaction did not preserve CRLF style.'
    Undo-GitIgnoreRuleAtomic $gitTransaction
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($gitignorePath)) -ceq [Convert]::ToBase64String($originalIgnoreBytes)) '.gitignore rollback did not restore the original bytes exactly.'

    $plainBytes = (New-Object Text.UTF8Encoding($false)).GetBytes('plain')
    [IO.File]::WriteAllBytes($gitignorePath, $plainBytes)
    $env:MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_REPLACE = '1'
    $replaceConflict = $false
    try { $null = Add-GitIgnoreRuleAtomic -Path $gitignorePath -Rule '/packages/app/.conda/' }
    catch { $replaceConflict = $_.Exception.Message -match 'external bytes were restored' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_REPLACE -ErrorAction SilentlyContinue }
    Assert-True $replaceConflict '.gitignore final-window writer was not detected and restored.'
    Assert-True ([IO.File]::ReadAllText($gitignorePath) -ceq 'external-at-replace') 'Final-window .gitignore writer was not restored to canonical state.'

    [IO.File]::WriteAllBytes($gitignorePath, $plainBytes)
    $rollbackTransaction = Add-GitIgnoreRuleAtomic -Path $gitignorePath -Rule '/packages/app/.conda/'
    $env:MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_ROLLBACK_REPLACE = '1'
    $rollbackConflict = $false
    try { Undo-GitIgnoreRuleAtomic $rollbackTransaction }
    catch { $rollbackConflict = $_.Exception.Message -match 'external bytes were restored' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_ROLLBACK_REPLACE -ErrorAction SilentlyContinue }
    Assert-True $rollbackConflict '.gitignore rollback final-window writer was not detected and restored.'
    Assert-True ([IO.File]::ReadAllText($gitignorePath) -ceq 'external-at-rollback') 'Rollback final-window .gitignore writer was not restored to canonical state.'
    $ignoreResidue = @(Get-ChildItem -LiteralPath $gitCase -Force | Where-Object { $_.Name -match 'miniconda-(?:stage|replace-backup|rollback)' })
    Assert-True ($ignoreResidue.Count -eq 0) '.gitignore conflict tests left transaction residue.'
}
finally {
    Remove-TestTree $gitCase
}

$claimCase = Join-Path ([IO.Path]::GetTempPath()) ('mini-claim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $standaloneRoot = Join-Path $claimCase 'standalone'
    New-Item -ItemType Directory -Path $standaloneRoot -Force | Out-Null
    $scriptDirectory = Join-Path $claimCase '100% audit; [x]'
    $otherScriptDirectory = Join-Path $claimCase 'other'
    New-Item -ItemType Directory -Path $scriptDirectory,$otherScriptDirectory -Force | Out-Null
    $standaloneScript = Join-Path $scriptDirectory '100% audit; [x].py'
    $otherScript = Join-Path $otherScriptDirectory '100% audit; [x].py'
    [IO.File]::WriteAllText($standaloneScript, 'print(1)', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($otherScript, 'print(2)', (New-Object Text.UTF8Encoding($false)))
    $stablePlan = Get-StableStandaloneEnvironmentPath -TempEnvRoot $standaloneRoot `
        -ScriptPath $standaloneScript
    $sameStablePlan = Get-StableStandaloneEnvironmentPath -TempEnvRoot $standaloneRoot `
        -ScriptPath (Join-Path $scriptDirectory '.\100% audit; [x].py')
    $otherStablePlan = Get-StableStandaloneEnvironmentPath -TempEnvRoot $standaloneRoot `
        -ScriptPath $otherScript
    Assert-True ($stablePlan.EnvPath -ieq $sameStablePlan.EnvPath -and
        $stablePlan.ScriptIdentity -ceq $sameStablePlan.ScriptIdentity) 'Equivalent script path spelling changed the stable STANDALONE identity.'
    Assert-True ($stablePlan.EnvPath -ine $otherStablePlan.EnvPath) 'Same-named scripts in different directories shared a STANDALONE identity.'
    Assert-True ($stablePlan.EnvPath -notmatch '20[0-9]{6}') 'STANDALONE path still embeds a date and cannot be reused across days.'
    $stableClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $stablePlan.EnvPath
    $stableIdentity = Write-StandaloneEnvironmentIdentity -Claim $stableClaim `
        -TempEnvRoot $standaloneRoot -EnvPath $stablePlan.EnvPath `
        -ScriptPath $standaloneScript
    $unfinishedIdentityRejected = $false
    try { $null = Get-OwnedStandaloneEnvironment $standaloneRoot $standaloneScript }
    catch { $unfinishedIdentityRejected = $_.Exception.Message -match 'unresolved creation claim' }
    Assert-True $unfinishedIdentityRejected 'A STANDALONE prefix with an unfinished claim was reused.'
    Remove-ManagedEnvironmentClaim $stableClaim STANDALONE $stablePlan.EnvPath
    $stableOwned = Get-OwnedStandaloneEnvironment $standaloneRoot $standaloneScript
    Assert-True ((Test-Path -LiteralPath $stableIdentity.IdentityPath -PathType Leaf) -and
        $stableOwned.EnvPath -ieq $stablePlan.EnvPath -and
        -not (Test-Path -LiteralPath $stableClaim.Path)) 'Claim finalization did not preserve and validate durable STANDALONE identity.'
    [IO.File]::AppendAllText($stableIdentity.IdentityPath, 'tamper')
    $tamperedIdentityRejected = $false
    try { $null = Get-OwnedStandaloneEnvironment $standaloneRoot $standaloneScript }
    catch { $tamperedIdentityRejected = $true }
    Assert-True $tamperedIdentityRejected 'Tampered durable STANDALONE identity was accepted for reuse.'

    $futureScript = Join-Path $scriptDirectory 'future.py'
    $futurePlan = Get-StableStandaloneEnvironmentPath $standaloneRoot $futureScript
    $futureClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $futurePlan.EnvPath
    $missingScriptFinalizationRejected = $false
    try {
        $null = Write-StandaloneEnvironmentIdentity -Claim $futureClaim `
            -TempEnvRoot $standaloneRoot -EnvPath $futurePlan.EnvPath -ScriptPath $futureScript
    }
    catch { $missingScriptFinalizationRejected = $_.Exception.Message -match 'does not exist|must exist' }
    Assert-True ($missingScriptFinalizationRejected -and
        (Test-Path -LiteralPath $futureClaim.Path)) 'Planning did not allow a future script or finalization signed a nonexistent script.'
    Remove-OwnedManagedCondaEnv -Lifecycle STANDALONE -ManagedRoot $standaloneRoot `
        -EnvPath $futurePlan.EnvPath -CondaExe $env:ComSpec -Claim $futureClaim

    $standaloneEnv = Join-Path $standaloneRoot 'audit-20260713'
    $standaloneClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $standaloneEnv
    Assert-True ((Test-Path -LiteralPath $standaloneEnv -PathType Container) -and
        (Test-Path -LiteralPath $standaloneClaim.MarkerPath -PathType Leaf) -and
        (Test-Path -LiteralPath $standaloneClaim.Path -PathType Leaf)) 'Atomic claim did not reserve a directory with both marker and sibling claim.'
    $null = Assert-ManagedEnvironmentClaim -Claim $standaloneClaim `
        -Lifecycle STANDALONE -EnvPath $standaloneEnv
    Remove-ManagedEnvironmentClaim -Claim $standaloneClaim `
        -Lifecycle STANDALONE -EnvPath $standaloneEnv
    Assert-True ((Test-Path -LiteralPath $standaloneEnv -PathType Container) -and
        @(Get-ChildItem -LiteralPath $standaloneEnv -Force).Count -eq 0) 'Completing a kept env claim should retain an empty prefix but remove its marker.'
    Assert-True (-not (Test-Path -LiteralPath $standaloneClaim.Path)) 'Completing a kept env claim left its sibling claim.'
    Remove-Item -LiteralPath $standaloneEnv -Force

    $recoveryEnv = Join-Path $standaloneRoot 'recovery-20260713'
    $recoveryClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $recoveryEnv
    $loadedRecovery = Get-ManagedEnvironmentRecoveryClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $recoveryEnv
    Assert-True ($loadedRecovery -and $loadedRecovery.OwnerToken -ceq $recoveryClaim.OwnerToken -and
        $loadedRecovery.Fingerprint -ceq $recoveryClaim.Fingerprint) 'A valid unfinished claim could not be reloaded for explicit recovery.'
    Remove-OwnedManagedCondaEnv -Lifecycle STANDALONE -ManagedRoot $standaloneRoot `
        -EnvPath $recoveryEnv -CondaExe $env:ComSpec -Claim $loadedRecovery

    $finalizeEnv = Join-Path $standaloneRoot 'finalize-20260713'
    $finalizeClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
        -ManagedRoot $standaloneRoot -EnvPath $finalizeEnv
    $claimLock = [IO.File]::Open($finalizeClaim.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $finalizeRejected = $false
        try { Remove-ManagedEnvironmentClaim -Claim $finalizeClaim -Lifecycle STANDALONE -EnvPath $finalizeEnv }
        catch { $finalizeRejected = $true }
        Assert-True ($finalizeRejected -and
            (Test-Path -LiteralPath $finalizeClaim.Path -PathType Leaf) -and
            (Test-Path -LiteralPath $finalizeClaim.MarkerPath -PathType Leaf)) 'Failed claim finalization did not restore its marker for recovery.'
        $null = Get-ManagedEnvironmentRecoveryClaim -Lifecycle STANDALONE `
            -ManagedRoot $standaloneRoot -EnvPath $finalizeEnv
    }
    finally { $claimLock.Dispose() }
    Remove-ManagedEnvironmentClaim -Claim $finalizeClaim -Lifecycle STANDALONE -EnvPath $finalizeEnv
    Remove-Item -LiteralPath $finalizeEnv -Force

    $raceRoot = Join-Path $claimCase 'race'
    $raceEnv = Join-Path $raceRoot 'external-20260713'
    New-Item -ItemType Directory -Path $raceEnv -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $raceEnv 'sentinel.txt') -Value 'external' -Encoding ASCII
    $raceRejected = $false
    try { $null = New-ManagedEnvironmentClaim -Lifecycle STANDALONE -ManagedRoot $raceRoot -EnvPath $raceEnv }
    catch { $raceRejected = $_.Exception.Message -match 'already exists' }
    Assert-True $raceRejected 'Atomic claim accepted a prefix created by another writer.'
    Assert-True (Test-Path -LiteralPath (Join-Path $raceEnv 'sentinel.txt') -PathType Leaf) 'Rejected external prefix lost its sentinel.'

    $tempRoot = Join-Path $claimCase 'temp'
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $lowercaseEnv = Join-Path $tempRoot 'lowercase-a1b2c3'
    $lowercaseClaim = New-ManagedEnvironmentClaim -Lifecycle temp `
        -ManagedRoot $tempRoot -EnvPath $lowercaseEnv
    Assert-True ($lowercaseClaim.Lifecycle -ceq 'TEMP') 'Lower-case lifecycle input was not canonicalized before claim persistence.'
    Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $lowercaseEnv `
        -EnvName (Split-Path -Leaf $lowercaseEnv) -CondaExe $env:ComSpec -Claim $lowercaseClaim
    Assert-True (-not (Test-Path -LiteralPath $lowercaseEnv) -and
        -not (Test-Path -LiteralPath $lowercaseClaim.Path)) 'A canonicalized lower-case TEMP claim could not be cleaned.'
    $partialEnv = Join-Path $tempRoot 'partial-20260713-010203-a1b2c3'
    $partialClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP `
        -ManagedRoot $tempRoot -EnvPath $partialEnv
    Set-Content -LiteralPath (Join-Path $partialEnv 'partial.txt') -Value 'partial' -Encoding ASCII
    Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $partialEnv `
        -EnvName (Split-Path -Leaf $partialEnv) -CondaExe $env:ComSpec -Claim $partialClaim
    Assert-True (-not (Test-Path -LiteralPath $partialEnv) -and
        -not (Test-Path -LiteralPath $partialClaim.Path)) 'Claim-owned partial TEMP prefix was not removed exactly.'

    $danglingEnv = Join-Path $tempRoot 'dangling-a1b2c3'
    $danglingClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP -ManagedRoot $tempRoot -EnvPath $danglingEnv
    Remove-Item -LiteralPath $danglingEnv -Recurse -Force
    $danglingTarget = Join-Path $claimCase 'dangling-target'
    New-Item -ItemType Directory -Path $danglingTarget | Out-Null
    New-Item -ItemType Junction -Path $danglingEnv -Target $danglingTarget | Out-Null
    [IO.Directory]::Delete($danglingTarget)
    $danglingCleanupRejected = $false
    try {
        Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $danglingEnv `
            -EnvName (Split-Path -Leaf $danglingEnv) -CondaExe $env:ComSpec -Claim $danglingClaim
    }
    catch { $danglingCleanupRejected = $_.Exception.Message -match 'reparse point' }
    Assert-True ($danglingCleanupRejected -and (Get-LiteralWindowsNamespaceEntry $danglingEnv) -and
        (Test-Path -LiteralPath $danglingClaim.Path -PathType Leaf)) 'Dangling reparse cleanup did not fail closed with ownership evidence intact.'
    [IO.Directory]::Delete($danglingEnv)
    Remove-Item -LiteralPath $danglingClaim.Path -Force

    $lockedEnv = Join-Path $tempRoot 'locked-20260713-010203-a1b2c3'
    $lockedClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP `
        -ManagedRoot $tempRoot -EnvPath $lockedEnv
    $lockedFile = Join-Path $lockedEnv 'locked.bin'
    [IO.File]::WriteAllText($lockedFile, 'locked')
    $lockedStream = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockedRejected = $false
        try {
            Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $lockedEnv `
                -EnvName (Split-Path -Leaf $lockedEnv) -CondaExe $env:ComSpec -Claim $lockedClaim
        }
        catch { $lockedRejected = $true }
        Assert-True $lockedRejected 'Locked TEMP residual incorrectly reported successful cleanup.'
        Assert-True ((Test-Path -LiteralPath $lockedEnv -PathType Container) -and
            (Test-Path -LiteralPath $lockedClaim.MarkerPath -PathType Leaf) -and
            (Test-Path -LiteralPath $lockedClaim.Path -PathType Leaf)) 'Failed cleanup did not preserve env, marker, and claim for retry.'
    }
    finally { $lockedStream.Dispose() }
    Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $lockedEnv `
        -EnvName (Split-Path -Leaf $lockedEnv) -CondaExe $env:ComSpec -Claim $lockedClaim
    Assert-True (-not (Test-Path -LiteralPath $lockedEnv) -and
        -not (Test-Path -LiteralPath $lockedClaim.Path)) 'Retry after releasing a locked residual did not finish cleanup.'

    $fakeConda = Join-Path $claimCase 'fake-conda-remove.exe'
    $fakeCondaSource = @'
using System;
using System.IO;
public static class FakeCondaRemoval {
    public static int Main(string[] args) {
        string marker = Environment.GetEnvironmentVariable("MINI_FAKE_OWNER_MARKER");
        if (!String.IsNullOrWhiteSpace(marker) && File.Exists(marker)) File.Delete(marker);
        int exitCode;
        return Int32.TryParse(Environment.GetEnvironmentVariable("MINI_FAKE_REMOVE_EXIT"), out exitCode) ? exitCode : 0;
    }
}
'@
    Add-Type -TypeDefinition $fakeCondaSource -Language CSharp `
        -OutputAssembly $fakeConda -OutputType ConsoleApplication
    $condaLockedEnv = Join-Path $tempRoot 'conda-locked-20260713-010203-a1b2c3'
    $condaLockedClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP `
        -ManagedRoot $tempRoot -EnvPath $condaLockedEnv
    New-Item -ItemType Directory -Path (Join-Path $condaLockedEnv 'conda-meta') | Out-Null
    [IO.File]::WriteAllText((Join-Path $condaLockedEnv 'conda-meta\history'), 'fixture')
    $condaLockedFile = Join-Path $condaLockedEnv 'locked.bin'
    [IO.File]::WriteAllText($condaLockedFile, 'locked')
    $oldFakeMarker = $env:MINI_FAKE_OWNER_MARKER
    $env:MINI_FAKE_OWNER_MARKER = $condaLockedClaim.MarkerPath
    $condaLockedStream = [IO.File]::Open($condaLockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $condaLockedRejected = $false
        try {
            Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $condaLockedEnv `
                -EnvName (Split-Path -Leaf $condaLockedEnv) -CondaExe $fakeConda -Claim $condaLockedClaim
        }
        catch { $condaLockedRejected = $true }
        Assert-True ($condaLockedRejected -and
            (Test-Path -LiteralPath $condaLockedClaim.MarkerPath -PathType Leaf) -and
            (Test-Path -LiteralPath $condaLockedClaim.Path -PathType Leaf)) 'Conda-aware failure did not restore marker and preserve claim for retry.'
    }
    finally {
        $condaLockedStream.Dispose()
        if ($null -eq $oldFakeMarker) { Remove-Item Env:\MINI_FAKE_OWNER_MARKER -ErrorAction SilentlyContinue }
        else { $env:MINI_FAKE_OWNER_MARKER = $oldFakeMarker }
    }
    $env:MINI_FAKE_OWNER_MARKER = $condaLockedClaim.MarkerPath
    try {
        Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $condaLockedEnv `
            -EnvName (Split-Path -Leaf $condaLockedEnv) -CondaExe $fakeConda -Claim $condaLockedClaim
    }
    finally {
        if ($null -eq $oldFakeMarker) { Remove-Item Env:\MINI_FAKE_OWNER_MARKER -ErrorAction SilentlyContinue }
        else { $env:MINI_FAKE_OWNER_MARKER = $oldFakeMarker }
    }
    Assert-True (-not (Test-Path -LiteralPath $condaLockedEnv) -and
        -not (Test-Path -LiteralPath $condaLockedClaim.Path)) 'Conda-aware cleanup retry did not finish after the lock was released.'

    $nonzeroEnv = Join-Path $tempRoot 'conda-nonzero-20260713-010203-a1b2c3'
    $nonzeroClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP -ManagedRoot $tempRoot -EnvPath $nonzeroEnv
    New-Item -ItemType Directory -Path (Join-Path $nonzeroEnv 'conda-meta') | Out-Null
    [IO.File]::WriteAllText((Join-Path $nonzeroEnv 'conda-meta\history'), 'fixture')
    $oldFakeExit = $env:MINI_FAKE_REMOVE_EXIT
    $env:MINI_FAKE_OWNER_MARKER = $nonzeroClaim.MarkerPath
    $env:MINI_FAKE_REMOVE_EXIT = '7'
    try {
        $nonzeroRejected = $false
        try { Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $nonzeroEnv `
            -EnvName (Split-Path -Leaf $nonzeroEnv) -CondaExe $fakeConda -Claim $nonzeroClaim }
        catch { $nonzeroRejected = $_.Exception.Message -match 'exit code 7' }
        Assert-True ($nonzeroRejected -and (Test-Path -LiteralPath $nonzeroClaim.MarkerPath) -and
            (Test-Path -LiteralPath $nonzeroClaim.Path)) 'Nonzero conda removal did not restore marker and preserve retry state.'
        $env:MINI_FAKE_REMOVE_EXIT = '0'
        Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $nonzeroEnv `
            -EnvName (Split-Path -Leaf $nonzeroEnv) -CondaExe $fakeConda -Claim $nonzeroClaim
    }
    finally {
        if ($null -eq $oldFakeMarker) { Remove-Item Env:\MINI_FAKE_OWNER_MARKER -ErrorAction SilentlyContinue } else { $env:MINI_FAKE_OWNER_MARKER = $oldFakeMarker }
        if ($null -eq $oldFakeExit) { Remove-Item Env:\MINI_FAKE_REMOVE_EXIT -ErrorAction SilentlyContinue } else { $env:MINI_FAKE_REMOVE_EXIT = $oldFakeExit }
    }

    $tamperEnv = Join-Path $tempRoot 'tamper-20260713-010203-a1b2c3'
    $tamperClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP `
        -ManagedRoot $tempRoot -EnvPath $tamperEnv
    $claimBytes = [IO.File]::ReadAllBytes($tamperClaim.Path)
    [IO.File]::WriteAllText($tamperClaim.Path, 'tampered')
    $tamperRejected = $false
    try { $null = Assert-ManagedEnvironmentClaim -Claim $tamperClaim -Lifecycle TEMP -EnvPath $tamperEnv }
    catch { $tamperRejected = $_.Exception.Message -match 'changed' }
    Assert-True $tamperRejected 'Tampered sibling ownership claim was accepted.'
    [IO.File]::WriteAllBytes($tamperClaim.Path, $claimBytes)
    Remove-OwnedTempCondaEnv -TempEnvRoot $tempRoot -EnvPath $tamperEnv `
        -EnvName (Split-Path -Leaf $tamperEnv) -CondaExe $env:ComSpec -Claim $tamperClaim

    $fakeCondaRejected = $false
    try { $null = Resolve-ValidatedCondaExecutable -Candidate @($env:ComSpec) }
    catch { $fakeCondaRejected = $_.Exception.Message -match 'failed identity validation' }
    Assert-True $fakeCondaRejected 'An arbitrary exit-capable executable was accepted as conda.'

    $approvalRoot = Join-Path $claimCase 'approval-root'
    New-Item -ItemType Directory -Path $approvalRoot -Force | Out-Null
    $approvalArgs = @{
        Lifecycle = 'TEMP'
        ManagedRoot = $approvalRoot
        EnvPath = Join-Path $approvalRoot 'task-20260714-010203-a1b2c3'
        CondaExe = $env:ComSpec
        PythonVersion = '3.12'
        ChannelPolicy = 'isolated-conda-forge'
        CondaPackages = @('numpy>=1.26,<3')
        PipPackages = @('requests[socks]==2.32.0')
    }
    $approvedCreation = New-CondaEnvironmentCreationApproval @approvalArgs
    $lockedCreation = Assert-CondaEnvironmentCreationApproval `
        -ApprovedPlan $approvedCreation @approvalArgs
    Assert-True ("python=$($lockedCreation.PythonVersion)" -cne 'python=') 'Approved no-manifest argv produced a blank python= token.'
    $approvalDriveRoot = [IO.Path]::GetPathRoot($claimCase)
    $rootApprovalArgs = $approvalArgs.Clone()
    $rootApprovalArgs.ManagedRoot = $approvalDriveRoot
    $rootApprovalArgs.EnvPath = Join-Path $approvalDriveRoot `
        ('mini-approval-root-' + [guid]::NewGuid().ToString('N'))
    $rootApproval = New-CondaEnvironmentCreationApproval @rootApprovalArgs
    $null = Assert-CondaEnvironmentCreationApproval -ApprovedPlan $rootApproval @rootApprovalArgs
    Assert-True ($rootApproval.ManagedRoot -ceq $approvalDriveRoot) 'Approval canonicalization collapsed a drive root into a drive-relative path.'
    foreach ($change in @('PythonVersion', 'EnvPath', 'CondaPackages')) {
        $changedArgs = $approvalArgs.Clone()
        if ($change -ceq 'PythonVersion') { $changedArgs.PythonVersion = '3.13' }
        elseif ($change -ceq 'EnvPath') { $changedArgs.EnvPath = Join-Path $approvalRoot 'other-a1b2c3' }
        else { $changedArgs.CondaPackages = @('pandas') }
        $approvalDriftRejected = $false
        try { $null = Assert-CondaEnvironmentCreationApproval -ApprovedPlan $approvedCreation @changedArgs }
        catch { $approvalDriftRejected = $_.Exception.Message -match 'changed after confirmation' }
        Assert-True $approvalDriftRejected "No-manifest approval did not bind $change."
    }
    $changedChannelRecord = $approvedCreation | Select-Object *
    $changedChannelRecord.ChannelPolicy = 'preserve'
    $channelDriftRejected = $false
    try { $null = Assert-CondaEnvironmentCreationApproval -ApprovedPlan $changedChannelRecord @approvalArgs }
    catch { $channelDriftRejected = $true }
    Assert-True $channelDriftRejected 'No-manifest approval did not bind channel policy.'
    foreach ($evilSpec in @('--file', '-c', 'conda-forge::numpy', 'https://example.test/pkg', '..\local')) {
        $evilArgs = $approvalArgs.Clone(); $evilArgs.CondaPackages = @($evilSpec)
        $evilRejected = $false
        try { $null = New-CondaEnvironmentCreationApproval @evilArgs }
        catch { $evilRejected = $_.Exception.Message -match 'simple name/version/build spec' }
        Assert-True $evilRejected "Unsafe conda package spec reached an approved plan: $evilSpec"
    }
    $pythonPackageArgs = $approvalArgs.Clone()
    $pythonPackageArgs.CondaPackages = @('python=3.11')
    $pythonPackageRejected = $false
    try { $null = New-CondaEnvironmentCreationApproval @pythonPackageArgs }
    catch { $pythonPackageRejected = $_.Exception.Message -match 'PythonVersion' }
    Assert-True $pythonPackageRejected 'A conflicting Python package spec entered a separately version-bound creation approval.'
    foreach ($evilSpec in @('--index-url', 'pkg @ https://example.test/a.whl', '.\local')) {
        $evilArgs = $approvalArgs.Clone(); $evilArgs.PipPackages = @($evilSpec)
        $evilRejected = $false
        try { $null = New-CondaEnvironmentCreationApproval @evilArgs }
        catch { $evilRejected = $_.Exception.Message -match 'simple index name/version spec' }
        Assert-True $evilRejected "Unsafe pip package spec reached an approved plan: $evilSpec"
    }

    $savedCondaChild = (Get-Item Function:\Invoke-CondaProjectChild).ScriptBlock
    $savedCondaPythonProbe = (Get-Item Function:\Assert-CondaEnvironmentPython).ScriptBlock
    $savedNativeChecked = (Get-Item Function:\Invoke-NativeChecked).ScriptBlock
    $script:observedCondaInstallArguments = $null
    $script:observedPipExecutable = $null
    $script:observedPipArguments = $null
    try {
        Set-Item Function:\Invoke-CondaProjectChild -Value {
            param([string]$CondaExe, $Context, [string[]]$ArgumentList, [string]$Label)
            if (-not $Context.CondarcPath -or
                -not (Test-Path -LiteralPath $Context.CondarcPath -PathType Leaf)) {
                throw 'Fake isolated conda operation did not receive a held minimal CONDARC.'
            }
            $policyText = [IO.File]::ReadAllText([string]$Context.CondarcPath)
            if ($policyText -notmatch 'create_default_packages:\s*\[\]' -or
                $policyText -notmatch 'pinned_packages:\s*\[\]') {
                throw 'Fake isolated conda operation received an incomplete minimal CONDARC.'
            }
            $prefixIndex = [Array]::IndexOf($ArgumentList, '--prefix')
            if ($prefixIndex -lt 0) { throw 'Fake conda create did not receive --prefix.' }
            if ($ArgumentList[0] -ceq 'install') {
                $script:observedCondaInstallArguments = @($ArgumentList)
            }
            $prefix = [string]$ArgumentList[$prefixIndex + 1]
            $marker = Join-Path $prefix '.miniconda-python-env.owner.json'
            Remove-Item -LiteralPath $marker -Force -ErrorAction Stop
            [IO.File]::WriteAllText((Join-Path $prefix 'python.exe'), 'fake-python')
            return 'fake-create-ok'
        }
        Set-Item Function:\Assert-CondaEnvironmentPython -Value {
            param([string]$EnvPath, [string]$ExpectedMajorMinor)
            $marker = Join-Path $EnvPath '.miniconda-python-env.owner.json'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
                throw 'Marker was not restored before the Python health probe.'
            }
            return Join-Path $EnvPath 'python.exe'
        }
        Set-Item Function:\Invoke-NativeChecked -Value {
            param([scriptblock]$Command, [string]$Label)
            $script:observedPipExecutable = (Get-Variable pythonExe -Scope 1 -ErrorAction Stop).Value
            $script:observedPipArguments = @((Get-Variable packages -Scope 1 -ErrorAction Stop).Value)
            return 'fake-pip-ok'
        }

        $fakeTempEnv = Join-Path $approvalRoot 'marker-temp-a1b2c3'
        $fakeTempClaim = New-ManagedEnvironmentClaim -Lifecycle TEMP `
            -ManagedRoot $approvalRoot -EnvPath $fakeTempEnv
        $fakeTempResult = Invoke-CondaEnvironmentCreate -CondaExe $env:ComSpec `
            -EnvPath $fakeTempEnv -PythonVersion 3.12 -Lifecycle TEMP `
            -ManagedRoot $approvalRoot -Claim $fakeTempClaim
        Assert-True ($fakeTempResult.PythonExe -ieq (Join-Path $fakeTempEnv 'python.exe') -and
            (Test-Path -LiteralPath $fakeTempClaim.MarkerPath -PathType Leaf)) 'No-manifest TEMP create did not restore a marker removed by conda.'
        $fakeBootstrapArgs = $approvalArgs.Clone()
        $fakeBootstrapArgs.EnvPath = $fakeTempEnv
        $fakeBootstrapArgs.CondaPackages = @('numpy>=1.26,<3')
        $fakeBootstrapArgs.PipPackages = @('requests==2.32.3')
        $fakeBootstrapPlan = New-CondaEnvironmentCreationApproval @fakeBootstrapArgs
        $null = Invoke-CondaEnvironmentPackageInstall `
            -ApprovedPlan $fakeBootstrapPlan -Claim $fakeTempClaim
        Assert-True ($script:observedCondaInstallArguments -contains 'python=3.12') `
            'Conda dependency install did not constrain the approved Python major.minor.'
        $null = Invoke-PipEnvironmentPackageInstall `
            -ApprovedPlan $fakeBootstrapPlan -Claim $fakeTempClaim
        Assert-True ($script:observedPipExecutable -ieq (Join-Path $fakeTempEnv 'python.exe') -and
            $script:observedPipArguments -contains 'requests==2.32.3') `
            'Pip dependency install did not use the locked interpreter/package plan.'
        $tamperedBootstrapPlan = $fakeBootstrapPlan | Select-Object *
        $tamperedBootstrapPlan.PythonVersion = '3.13'
        $tamperedBootstrapRejected = $false
        try {
            $null = Invoke-CondaEnvironmentPackageInstall `
                -ApprovedPlan $tamperedBootstrapPlan -Claim $fakeTempClaim
        }
        catch { $tamperedBootstrapRejected = $_.Exception.Message -match 'incomplete or changed' }
        Assert-True $tamperedBootstrapRejected 'Dependency bootstrap accepted a mutated post-confirmation approval record.'
        Remove-OwnedTempCondaEnv -TempEnvRoot $approvalRoot -EnvPath $fakeTempEnv `
            -EnvName (Split-Path -Leaf $fakeTempEnv) -CondaExe $env:ComSpec `
            -Claim $fakeTempClaim
        Assert-True (-not (Test-Path -LiteralPath $fakeTempEnv) -and
            -not (Test-Path -LiteralPath $fakeTempClaim.Path)) 'Marker-restored TEMP create could not be cleaned through exact ownership.'

        $fakeStandaloneScript = Join-Path $otherScriptDirectory 'fake-create.py'
        [IO.File]::WriteAllText($fakeStandaloneScript, 'print(3)', (New-Object Text.UTF8Encoding($false)))
        $fakeStandalonePlan = Get-StableStandaloneEnvironmentPath $standaloneRoot $fakeStandaloneScript
        $fakeStandaloneClaim = New-ManagedEnvironmentClaim -Lifecycle STANDALONE `
            -ManagedRoot $standaloneRoot -EnvPath $fakeStandalonePlan.EnvPath
        $fakeStandaloneResult = Invoke-CondaEnvironmentCreate -CondaExe $env:ComSpec `
            -EnvPath $fakeStandalonePlan.EnvPath -PythonVersion 3.12 `
            -Lifecycle STANDALONE -ManagedRoot $standaloneRoot `
            -Claim $fakeStandaloneClaim
        $fakeStandaloneIdentity = Write-StandaloneEnvironmentIdentity `
            -Claim $fakeStandaloneClaim -TempEnvRoot $standaloneRoot `
            -EnvPath $fakeStandalonePlan.EnvPath -ScriptPath $fakeStandaloneScript
        Remove-ManagedEnvironmentClaim $fakeStandaloneClaim STANDALONE `
            $fakeStandalonePlan.EnvPath
        Assert-True ((Test-Path -LiteralPath $fakeStandaloneIdentity.IdentityPath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $fakeStandaloneClaim.Path)) 'Marker-restored STANDALONE create could not finalize durable identity.'
    }
    finally {
        Set-Item Function:\Invoke-CondaProjectChild -Value $savedCondaChild
        Set-Item Function:\Assert-CondaEnvironmentPython -Value $savedCondaPythonProbe
        Set-Item Function:\Invoke-NativeChecked -Value $savedNativeChecked
        Remove-Variable observedCondaInstallArguments -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable observedPipExecutable -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable observedPipArguments -Scope Script -ErrorAction SilentlyContinue
    }

    $savedExportCondaChild = (Get-Item Function:\Invoke-CondaProjectChild).ScriptBlock
    try {
        Set-Item Function:\Invoke-CondaProjectChild -Value {
            param([string]$CondaExe, $Context, [string[]]$ArgumentList, [string]$Label)
            return "name: audit`nchannels:`n  - conda-forge`ndependencies:`n  - python=3.12`n  - pip=26`n  - pip:`n    - requests==2.32.3`n"
        }
        $pipExportRejected = $false
        try {
            $null = Invoke-CondaEnvironmentYamlExport -CondaExe $env:ComSpec `
                -EnvPath $approvalRoot -ChannelPolicy preserve
        }
        catch { $pipExportRejected = $_.Exception.Message -match 'pip subsection.*not bound' }
        Assert-True $pipExportRejected 'Conda export emitted a pip subsection that the PROJECT restore policy rejects.'
    }
    finally { Set-Item Function:\Invoke-CondaProjectChild -Value $savedExportCondaChild }

    $manifestWriteDirectory = Join-Path $claimCase '100% manifests; [x]'
    New-Item -ItemType Directory -Path $manifestWriteDirectory -Force | Out-Null
    $manifestWritePath = Join-Path $manifestWriteDirectory 'environment.yml'
    $manifestUtf8 = New-Object Text.UTF8Encoding($false, $true)
    [IO.File]::WriteAllText($manifestWritePath,
        "channels:`r`n  - old`r`ndependencies:`r`n  - python=3.11`r`n", $manifestUtf8)
    $manifestObserved = Get-CondaEnvironmentManifestState $manifestWritePath
    $manifestResult = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
        -Yaml "channels:`n  - conda-forge`ndependencies:`n  - python=3.12`n" `
        -ExpectedState $manifestObserved -Action Replace
    Assert-True ($manifestResult.Changed -and
        (Test-Path -LiteralPath $manifestResult.BackupPath -PathType Leaf)) 'Atomic manifest replacement did not retain the exact old bytes as a backup.'
    $manifestAfter = Get-CondaEnvironmentManifestState $manifestWritePath
    $manifestEquivalent = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
        -Yaml ($manifestAfter.Content.Replace("`n", "`r`n")) `
        -ExpectedState $manifestAfter -Action Replace
    Assert-True (-not $manifestEquivalent.Changed -and
        $manifestEquivalent.Action -ceq 'Equivalent') 'Line-ending-equivalent manifest bytes caused an unnecessary replacement.'
    $caseActionState = Get-CondaEnvironmentManifestState $manifestWritePath
    $caseActionContent = $caseActionState.Content
    $keptLower = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
        -Yaml "channels:`n  - lower-keep`ndependencies:`n  - python=3.13`n" `
        -ExpectedState $caseActionState -Action keepexisting
    Assert-True (-not $keptLower.Changed -and $keptLower.Action -ceq 'KeepExisting' -and
        (Get-CondaEnvironmentManifestState $manifestWritePath).Content -ceq $caseActionContent) 'Lower-case KeepExisting unexpectedly replaced the canonical manifest.'
    $saveState = Get-CondaEnvironmentManifestState $manifestWritePath
    $savedLower = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
        -Yaml "channels:`n  - lower-save`ndependencies:`n  - python=3.13`n" `
        -ExpectedState $saveState -Action savegenerated
    Assert-True ($savedLower.Changed -and $savedLower.Action -ceq 'SaveGenerated' -and
        $savedLower.Path -ine $manifestWritePath -and
        (Get-CondaEnvironmentManifestState $manifestWritePath).Fingerprint -ceq $saveState.Fingerprint) 'Lower-case SaveGenerated replaced the canonical manifest.'
    $raceObserved = Get-CondaEnvironmentManifestState $manifestWritePath
    $env:MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_AT_REPLACE = '1'
    $manifestRaceRejected = $false
    try {
        $null = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
            -Yaml "channels:`n  - changed`ndependencies:`n  - python=3.13`n" `
            -ExpectedState $raceObserved -Action Replace
    }
    catch { $manifestRaceRejected = $_.Exception.Message -match 'external bytes were restored' }
    finally { Remove-Item Env:\MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_AT_REPLACE -ErrorAction SilentlyContinue }
    Assert-True ($manifestRaceRejected -and
        (Get-CondaEnvironmentManifestState $manifestWritePath).Content -match 'external') 'Manifest final-window mutation was not detected and restored.'
    $manifestResidue = @(Get-ChildItem -LiteralPath $manifestWriteDirectory -Force |
        Where-Object { $_.Name -match '^\.environment\.yml\.manifest-(?:stage|replace-backup)-[0-9a-f]{32}$' })
    Assert-True ($manifestResidue.Count -eq 0) 'Manifest final-window recovery left transaction residue.'

    [IO.File]::WriteAllText($manifestWritePath,
        "channels:`n  - before-second-race`n", $manifestUtf8)
    $secondRaceObserved = Get-CondaEnvironmentManifestState $manifestWritePath
    $env:MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_AT_REPLACE = '1'
    $env:MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_BEFORE_RESTORE = '1'
    $secondRestoreRejected = $false
    try {
        $null = Write-CondaEnvironmentManifestAtomic -Path $manifestWritePath `
            -Yaml "channels:`n  - skill-second`ndependencies:`n  - python=3.13`n" `
            -ExpectedState $secondRaceObserved -Action Replace
    }
    catch { $secondRestoreRejected = $_.Exception.Message -match 'changed during final restoration' }
    finally {
        Remove-Item Env:\MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_AT_REPLACE -ErrorAction SilentlyContinue
        Remove-Item Env:\MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_BEFORE_RESTORE -ErrorAction SilentlyContinue
    }
    $manifestResidue = @(Get-ChildItem -LiteralPath $manifestWriteDirectory -Force |
        Where-Object { $_.Name -match '^\.environment\.yml\.manifest-(?:stage|replace-backup)-[0-9a-f]{32}$' })
    Assert-True ($secondRestoreRejected -and $manifestResidue.Count -eq 1 -and
        [IO.File]::ReadAllText($manifestResidue[0].FullName) -match 'second-external') 'A second final-window writer was deleted instead of being preserved as recovery evidence.'
    Remove-Item -LiteralPath $manifestResidue[0].FullName -Force

    [IO.File]::WriteAllText($manifestWritePath,
        "channels:`n  - base`ndependencies:`n  - python=3.12`n", $manifestUtf8)
    $manifestGo = Join-Path $manifestWriteDirectory 'go'
    $manifestReadyA = Join-Path $manifestWriteDirectory 'ready-a'
    $manifestReadyB = Join-Path $manifestWriteDirectory 'ready-b'
    $manifestLiteral = ConvertTo-PowerShellLiteral $manifestWritePath
    $helperLiteral = ConvertTo-PowerShellLiteral $environmentHelpers
    $manifestWriterA = Start-RedirectedPowerShell ('. ' + $helperLiteral +
        '; $state=Get-CondaEnvironmentManifestState ' + $manifestLiteral +
        '; [IO.File]::WriteAllText(' + (ConvertTo-PowerShellLiteral $manifestReadyA) + ',''ready'')' +
        '; while(-not(Test-Path -LiteralPath ' + (ConvertTo-PowerShellLiteral $manifestGo) + ')){Start-Sleep -Milliseconds 10}' +
        '; $null=Write-CondaEnvironmentManifestAtomic -Path ' + $manifestLiteral +
        ' -Yaml "channels:`n  - alpha`ndependencies:`n  - python=3.12`n" -ExpectedState $state -Action Replace')
    $manifestWriterB = Start-RedirectedPowerShell ('. ' + $helperLiteral +
        '; $state=Get-CondaEnvironmentManifestState ' + $manifestLiteral +
        '; [IO.File]::WriteAllText(' + (ConvertTo-PowerShellLiteral $manifestReadyB) + ',''ready'')' +
        '; while(-not(Test-Path -LiteralPath ' + (ConvertTo-PowerShellLiteral $manifestGo) + ')){Start-Sleep -Milliseconds 10}' +
        '; $null=Write-CondaEnvironmentManifestAtomic -Path ' + $manifestLiteral +
        ' -Yaml "channels:`n  - beta`ndependencies:`n  - python=3.12`n" -ExpectedState $state -Action Replace')
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((-not (Test-Path -LiteralPath $manifestReadyA) -or
            -not (Test-Path -LiteralPath $manifestReadyB)) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        Assert-True ((Test-Path -LiteralPath $manifestReadyA) -and
            (Test-Path -LiteralPath $manifestReadyB)) 'Concurrent manifest writers did not both capture the same observed state.'
        [IO.File]::WriteAllText($manifestGo, 'go')
        $manifestConcurrentA = Complete-RedirectedPowerShell $manifestWriterA 15
        $manifestWriterA = $null
        $manifestConcurrentB = Complete-RedirectedPowerShell $manifestWriterB 15
        $manifestWriterB = $null
        $manifestExitCodes = @($manifestConcurrentA.ExitCode, $manifestConcurrentB.ExitCode)
        Assert-True (($manifestExitCodes | Where-Object { $_ -eq 0 }).Count -eq 1 -and
            ($manifestExitCodes | Where-Object { $_ -ne 0 }).Count -eq 1) 'Two different YAML writers did not produce exactly one CAS winner.'
        $concurrentManifest = (Get-CondaEnvironmentManifestState $manifestWritePath).Content
        Assert-True ($concurrentManifest -match '  - (?:alpha|beta)') 'Concurrent manifest winner did not commit one complete YAML document.'
        $manifestResidue = @(Get-ChildItem -LiteralPath $manifestWriteDirectory -Force |
            Where-Object { $_.Name -match '^\.environment\.yml\.manifest-(?:stage|replace-backup)-[0-9a-f]{32}$' })
        Assert-True ($manifestResidue.Count -eq 0) 'Concurrent manifest writers left transaction residue.'
    }
    finally {
        if (-not (Test-Path -LiteralPath $manifestGo)) { [IO.File]::WriteAllText($manifestGo, 'go') }
        foreach ($handle in @($manifestWriterA, $manifestWriterB) | Where-Object { $_ }) {
            try { $null = Complete-RedirectedPowerShell $handle 5 } catch {}
        }
    }

    $manifestPath = Join-Path $claimCase 'environment.yml'
    [IO.File]::WriteAllText($manifestPath, "channels:`r`n  - conda-forge`r`n  - nodefaults`r`ndependencies:`r`n  - python=3.12`r`n", (New-Object Text.UTF8Encoding($true)))
    $safeChannels = @(Get-IsolatableProjectManifestChannels $manifestPath)
    Assert-True ($safeChannels.Count -eq 2 -and $safeChannels -ccontains 'conda-forge' -and
        $safeChannels -ccontains 'nodefaults') 'Explicit public nodefaults manifest was not eligible for child-scoped isolation.'
    foreach ($unsafeManifest in @(
        "channels: [defaults, nodefaults]`ndependencies: []`n",
        "channels: [private-team, nodefaults]`ndependencies: []`n",
        "channels: [conda-forge, nodefaults]`ndependencies: [private-team::secret]`n",
        "dependencies: [python=3.12]`n"
    )) {
        [IO.File]::WriteAllText($manifestPath, $unsafeManifest, (New-Object Text.UTF8Encoding($false)))
        $unsafeRejected = $false
        try { $null = Get-IsolatableProjectManifestChannels $manifestPath }
        catch { $unsafeRejected = $true }
        Assert-True $unsafeRejected 'Unsafe/default/private/missing channel policy was silently remapped through minimal CONDARC.'
    }

    [IO.File]::WriteAllText($manifestPath, "channels:`n  - conda-forge`n  - nodefaults`ndependencies:`n  - python=3.12`n", (New-Object Text.UTF8Encoding($false)))
    $context = New-CondaProjectExecutionContext -ManifestPath $manifestPath
    $condarcPath = $context.CondarcPath
    try {
        $condarcRename = $condarcPath + '.swapped'
        $condarcMoveBlocked = $false
        try { [IO.File]::Move($condarcPath, $condarcRename) }
        catch { $condarcMoveBlocked = $true }
        Assert-True $condarcMoveBlocked 'Held minimal CONDARC allowed path substitution while the child policy was active.'
        $contextRead = Invoke-CondaProjectChild -CondaExe (Get-Command powershell.exe).Source `
            -ArgumentList @('-NoProfile', '-Command', '[Console]::Out.Write([IO.File]::ReadAllText($env:CONDARC));[Console]::Out.Write([char]124);[Console]::Out.Write($env:CI);[Console]::Out.Write([char]124);[Console]::Out.Write($env:CONDA_PLUGINS_AUTO_ACCEPT_TOS)') `
            -Context $context -Label 'held minimal CONDARC fixture'
        Assert-True ($contextRead -match '(?s)channels:\s*\[\].*\|false\|false') 'Conda child could not read the held minimal CONDARC or inherited CI/ToS controls.'
    }
    finally { Close-CondaProjectExecutionContext $context }
    Assert-True (-not (Test-Path -LiteralPath $condarcPath)) 'Held minimal CONDARC was not securely removed.'
    [IO.File]::WriteAllText($manifestPath, "channels: [https://user:secret@example.invalid/team, nodefaults]`ndependencies: [python=3.12]`n", (New-Object Text.UTF8Encoding($false)))
    $inlineSecretRejected = $false
    try { $null = New-CondaProjectExecutionContext -ManifestPath $manifestPath }
    catch { $inlineSecretRejected = $_.Exception.Message -match 'URL credentials' }
    Assert-True $inlineSecretRejected 'PROJECT context copied an inline channel credential into child execution.'
    [IO.File]::WriteAllText($manifestPath, "channels:`n  - conda-forge`n  - nodefaults`ndependencies:`n  - python=3.12`n", (New-Object Text.UTF8Encoding($false)))

    $planFixture = @{ actions = @{ LINK = @(
        @{ name = 'python'; version = '3.12.13'; channel = 'https://user:secret@repo.anaconda.com/pkgs/main'; url = 'https://user:secret@repo.anaconda.com/pkgs/main/win-64/a-1.conda' },
        @{ base_url = 'https://conda.anaconda.org/t/private-token/team/channel'; url = 'file:///C:/cache/team/win-64/b-1.tar.bz2' }
    ) } } | ConvertTo-Json -Depth 10 -Compress
    $channelConfigFixture = @{ channel_alias = @{ scheme = 'https'; location = 'conda.anaconda.org'; name = ''; token = $null }; custom_channels = @{}; custom_multichannels = @{} } | ConvertTo-Json -Depth 10 -Compress
    $planState = Get-CondaPlanState -Json $planFixture -ChannelConfigurationJson $channelConfigFixture
    $planSources = $planState.ResolvedSources -join '|'
    Assert-True ($planState.PackageCount -eq 2 -and $planState.PythonMajorMinor -ceq '3.12' -and
        $planSources -match 'repo\.anaconda\.com/pkgs/main' -and
        $planSources -match 'file:///C:/cache/team' -and $planSources -notmatch 'secret|private-token') 'Conda preview sources were incomplete or leaked URL credentials/tokens.'
    $modernPlanFixture = @{ name = $null; channels = @('conda-forge', 'nodefaults'); variables = @{ AUDIT_FLAG = 'not-displayed' }; dependencies = @(
        'conda-forge/noarch::pip==26.1.2=pyh8b19718_0',
        'conda-forge/win-64::python==3.12.13=h0159041_0_cpython'
    ) } | ConvertTo-Json -Depth 10 -Compress
    $modernPlan = Get-CondaPlanState -Json $modernPlanFixture -ChannelConfigurationJson $channelConfigFixture
    Assert-True ($modernPlan.PackageCount -eq 2 -and $modernPlan.VariableNames -contains 'AUDIT_FLAG' -and
        $modernPlan.PythonVersion -ceq '3.12.13' -and
        ($modernPlan.ResolvedSources -join '|') -match '^https://conda\.anaconda\.org/conda-forge$') 'Conda 26 channels/dependencies dry-run schema was not counted and resolved.'
    $noPythonRejected = $false
    try {
        $null = Get-CondaPlanState -Json (@{ channels = @('conda-forge'); dependencies = @('conda-forge/win-64::r-base==4.5.1=h1') } | ConvertTo-Json -Compress) `
            -ChannelConfigurationJson $channelConfigFixture
    }
    catch { $noPythonRejected = $_.Exception.Message -match 'exactly one Python' }
    Assert-True $noPythonRejected 'A PROJECT solve without Python reached creation.'
    $pipMappingRejected = $false
    try {
        $null = Get-CondaPlanState -Json (@{ channels = @('conda-forge'); dependencies = @(
            'conda-forge/win-64::python==3.12.13=h1', @{ pip = @('example-package==1.0') }) } | ConvertTo-Json -Depth 10 -Compress) `
            -ChannelConfigurationJson $channelConfigFixture
    }
    catch { $pipMappingRejected = $_.Exception.Message -match 'pip sections' }
    Assert-True $pipMappingRejected 'A PROJECT pip mapping bypassed source-bound post-conda policy.'
    Assert-True ((ConvertTo-RedactedCondaPlanSource -Value 'file://server/share/channel/win-arm64/a-1.conda' -FieldName url) -ceq 'file://server/share/channel') 'UNC file channel host or win-arm64 subdir was lost during source redaction.'
    $approvalFingerprint = Get-CondaProjectApprovalFingerprint -ManifestPath $manifestPath `
        -EnvPath (Join-Path $claimCase '.conda') -CondaExe $env:ComSpec `
        -UseInheritedConfiguration $false `
        -ManifestFingerprint ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) -Plan $modernPlan
    $changedPlan = $modernPlan | Select-Object *
    $changedPlan.PythonVersion = '3.13.1'
    Assert-True ($approvalFingerprint -cne (Get-CondaProjectApprovalFingerprint -ManifestPath $manifestPath `
        -EnvPath (Join-Path $claimCase '.conda') -CondaExe $env:ComSpec `
        -UseInheritedConfiguration $false `
        -ManifestFingerprint ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) -Plan $changedPlan)) 'Approval fingerprint did not bind displayed Python details.'
    Assert-True ($approvalFingerprint -cne (Get-CondaProjectApprovalFingerprint -ManifestPath $manifestPath `
        -EnvPath (Join-Path $claimCase '.conda') -CondaExe (Get-Command powershell.exe).Source `
        -UseInheritedConfiguration $false `
        -ManifestFingerprint ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash) -Plan $modernPlan)) 'Approval fingerprint did not bind the conda executable path.'
    $normalizedYaml = Set-CondaYamlChannelPolicy -Yaml "channels:`n  - defaults`ndependencies:`n  - python=3.12`nprefix: C:\fixture`n" `
        -Channel @('https://conda.anaconda.org/conda-forge')
    Assert-True ($normalizedYaml -match "(?m)^  - 'nodefaults'$" -and
        $normalizedYaml -notmatch '(?m)^\s+- defaults$') 'Isolated export did not replace inherited channels with an exact nodefaults policy.'
    $metadataFree = Remove-CondaYamlMachineMetadata "name: >-`n  C:\long\prefix`nchannels:`n  - conda-forge`ndependencies:`n  - python=3.12`nprefix: >-`n  C:\long\prefix`n"
    Assert-True ($metadataFree -notmatch 'C:\\long|(?m)^(?:name|prefix):' -and
        $metadataFree -match '(?m)^dependencies:') 'Wrapped Windows prefix/name metadata survived export filtering.'
    $installedFixture = @(@{ name = 'python'; channel = 'pkgs/main'; base_url = 'https://repo.anaconda.com/pkgs/main' }) | ConvertTo-Json -Compress
    Assert-True ((Get-CondaInstalledChannelSources -Json $installedFixture `
        -Configuration ($channelConfigFixture | ConvertFrom-Json)) -contains 'https://repo.anaconda.com/pkgs/main') 'Installed package channel audit lost base_url provenance.'

    $identityRoot = Join-Path $claimCase 'identity'
    $misnamedVenv = Join-Path $identityRoot '.conda'
    $misnamedConda = Join-Path $identityRoot '.venv'
    New-Item -ItemType Directory -Path (Join-Path $misnamedVenv 'Scripts'),(Join-Path $misnamedConda 'conda-meta') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $misnamedVenv 'pyvenv.cfg'), 'home = fixture')
    [IO.File]::WriteAllText((Join-Path $misnamedVenv 'Scripts\python.exe'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $misnamedConda 'conda-meta\history'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $misnamedConda 'python.exe'), 'fixture')
    $savedExactProbe = (Get-Item Function:\Assert-ExactPythonInterpreter).ScriptBlock
    try {
        Set-Item Function:\Assert-ExactPythonInterpreter -Value {
            param([string]$PythonExe, [string]$ExpectedMajorMinor)
            if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) { throw "Missing fixture interpreter: $PythonExe" }
            [IO.Path]::GetFullPath($PythonExe)
        }
        $venvIdentity = Get-ExistingPythonEnvironmentIdentity $misnamedVenv
        $condaIdentity = Get-ExistingPythonEnvironmentIdentity $misnamedConda
        Assert-True ($venvIdentity.Kind -ceq 'venv' -and $venvIdentity.PythonExe -match 'Scripts\\python\.exe$') 'A venv named .conda was not identified by pyvenv.cfg and Scripts\\python.exe.'
        Assert-True ($condaIdentity.Kind -ceq 'conda' -and $condaIdentity.PythonExe -notmatch 'Scripts') 'A conda env named .venv was not identified by conda-meta/history.'
        New-Item -ItemType Directory -Path (Join-Path $misnamedVenv 'conda-meta') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $misnamedVenv 'conda-meta\history'), 'ambiguous')
        $ambiguousRejected = $false
        try { $null = Get-ExistingPythonEnvironmentIdentity $misnamedVenv }
        catch { $ambiguousRejected = $_.Exception.Message -match 'ambiguous' }
        Assert-True $ambiguousRejected 'An environment with both conda and venv identity markers was accepted.'
    }
    finally { Set-Item Function:\Assert-ExactPythonInterpreter -Value $savedExactProbe }

    Assert-True ((ConvertTo-WindowsNativeArgument 'plain') -ceq 'plain') 'Native argument encoder unnecessarily quoted a plain token.'
    Assert-True ((ConvertTo-WindowsNativeArgument 'space value') -ceq '"space value"') 'Native argument encoder mishandled whitespace.'
    $oldChildOnly = $env:MINI_CHILD_ONLY
    $oldCondaChannels = $env:CONDA_CHANNELS
    $oldCi = $env:CI
    $oldAutoAccept = $env:CONDA_PLUGINS_AUTO_ACCEPT_TOS
    try {
        $env:MINI_CHILD_ONLY = 'parent'
        $env:CONDA_CHANNELS = 'defaults'
        $env:CI = 'true'
        $env:CONDA_PLUGINS_AUTO_ACCEPT_TOS = 'true'
        $childValue = Invoke-ProcessCapturedChecked -FilePath (Get-Command powershell.exe).Source `
            -ArgumentList @('-NoProfile', '-Command', '[Console]::Out.Write([string]$env:CONDA_CHANNELS);[Console]::Out.Write([char]124);[Console]::Out.Write($env:MINI_CHILD_ONLY);[Console]::Out.Write([char]124);[Console]::Out.Write($env:APPDATA);[Console]::Out.Write([char]124);[Console]::Out.Write($env:ComSpec);[Console]::Out.Write([char]124);[Console]::Out.Write($env:CI);[Console]::Out.Write([char]124);[Console]::Out.Write($env:CONDA_PLUGINS_AUTO_ACCEPT_TOS)') `
            -Environment @{ MINI_CHILD_ONLY = 'child value'; CI = 'false'; CONDA_PLUGINS_AUTO_ACCEPT_TOS = 'false' } `
            -RemoveEnvironmentNamePattern '^(?:CONDA_|_CE_|CI$)' -Label 'child-only environment fixture'
        $childParts = @($childValue -split '\|', 6)
        Assert-True ($childParts.Count -eq 6 -and $childParts[0] -ceq '' -and
            $childParts[1] -ceq 'child value' -and $childParts[2] -ceq $env:APPDATA -and
            $childParts[3] -ceq $env:ComSpec -and $childParts[4] -ceq 'false' -and
            $childParts[5] -ceq 'false') 'Child environment was incomplete or failed channel/ToS sanitization.'
        Assert-True ($env:MINI_CHILD_ONLY -ceq 'parent') 'Child-scoped environment override mutated the parent process.'
        Assert-True ($env:CONDA_CHANNELS -ceq 'defaults') 'Child-scoped conda sanitization mutated the parent process.'
        Assert-True ($env:CI -ceq 'true' -and $env:CONDA_PLUGINS_AUTO_ACCEPT_TOS -ceq 'true') 'Child ToS guards mutated the parent process.'
    }
    finally {
        if ($null -eq $oldChildOnly) { Remove-Item Env:\MINI_CHILD_ONLY -ErrorAction SilentlyContinue }
        else { $env:MINI_CHILD_ONLY = $oldChildOnly }
        if ($null -eq $oldCondaChannels) { Remove-Item Env:\CONDA_CHANNELS -ErrorAction SilentlyContinue }
        else { $env:CONDA_CHANNELS = $oldCondaChannels }
        if ($null -eq $oldCi) { Remove-Item Env:\CI -ErrorAction SilentlyContinue } else { $env:CI = $oldCi }
        if ($null -eq $oldAutoAccept) { Remove-Item Env:\CONDA_PLUGINS_AUTO_ACCEPT_TOS -ErrorAction SilentlyContinue }
        else { $env:CONDA_PLUGINS_AUTO_ACCEPT_TOS = $oldAutoAccept }
    }

    $projectCleanupRoot = Join-Path $claimCase 'project-cleanup'
    New-Item -ItemType Directory -Path $projectCleanupRoot -Force | Out-Null
    $projectCleanupEnv = Join-Path $projectCleanupRoot '.conda'
    $projectCleanupClaim = New-ManagedEnvironmentClaim -Lifecycle PROJECT `
        -ManagedRoot $projectCleanupRoot -EnvPath $projectCleanupEnv
    Set-Content -LiteralPath (Join-Path $projectCleanupEnv 'partial.txt') -Value 'partial' -Encoding ASCII
    Remove-OwnedManagedCondaEnv -Lifecycle PROJECT -ManagedRoot $projectCleanupRoot `
        -EnvPath $projectCleanupEnv -CondaExe $env:ComSpec -Claim $projectCleanupClaim
    Assert-True (-not (Test-Path -LiteralPath $projectCleanupEnv) -and
        -not (Test-Path -LiteralPath $projectCleanupClaim.Path)) 'Failed kept-environment creation did not clean its exact owned partial prefix.'

    $mutexEnv = Join-Path $tempRoot 'mutex-20260713-010203-a1b2c3'
    $heldPrefixLock = Enter-ManagedEnvironmentMutex -EnvPath $mutexEnv
    try {
        $helperLiteral = ConvertTo-PowerShellLiteral $environmentHelpers
        $mutexLiteral = ConvertTo-PowerShellLiteral $mutexEnv
        $contender = Invoke-RedirectedPowerShell ('. ' + $helperLiteral +
            '; $null=Enter-ManagedEnvironmentMutex -EnvPath ' + $mutexLiteral +
            ' -TimeoutSeconds 1')
        Assert-True ($contender.ExitCode -eq 1 -and $contender.Output -match 'Timed out waiting') 'A second process entered the same canonical-prefix mutex.'
    }
    finally { Exit-ManagedEnvironmentMutex $heldPrefixLock }

    $realCondaPython = 'D:\Tools\miniconda3\python.exe'
    if (Test-Path -LiteralPath $realCondaPython -PathType Leaf) {
        $realCondaRoot = Split-Path -Parent $realCondaPython
        $realCondaExe = Join-Path $realCondaRoot 'Scripts\conda.exe'
        $invalidFirstRejected = $false
        try { $null = Resolve-ValidatedCondaExecutable -Candidate @($env:ComSpec, $realCondaExe) }
        catch { $invalidFirstRejected = $_.Exception.Message -match 'refusing fallback' }
        Assert-True $invalidFirstRejected 'An existing invalid first conda candidate silently fell through to a later executable.'
        Assert-True ((Assert-CondaEnvironmentPython -EnvPath $realCondaRoot) -ieq $realCondaPython) 'Real Windows PowerShell 5.1 Python health probe failed.'
        $realCondaIdentity = Get-ExistingPythonEnvironmentIdentity $realCondaRoot
        Assert-True ($realCondaIdentity.Kind -ceq 'conda' -and $realCondaIdentity.PythonExe -ieq $realCondaPython) 'Real Miniconda root identity was not proved from conda-meta/history.'

        $pipManifest = Join-Path $claimCase 'parser-pip-environment.yml'
        [IO.File]::WriteAllText($pipManifest,
            "name: audit`nchannels:`n  - https://conda.anaconda.org/conda-forge`n  - nodefaults`ndependencies:`n  - python=3.12`n  - pip`n  - pip:`n    - requests==2.32.3`nvariables:`n  AUDIT_FLAG: hidden`n",
            (New-Object Text.UTF8Encoding($false)))
        $pipContext = New-CondaProjectExecutionContext -ManifestPath $pipManifest
        $heldCondarcPath = $pipContext.CondarcPath
        try {
            $heldRenameRejected = $false
            try { Move-Item -LiteralPath $heldCondarcPath -Destination ($heldCondarcPath + '.moved') -ErrorAction Stop }
            catch { $heldRenameRejected = $true }
            Assert-True $heldRenameRejected 'Held minimal CONDARC allowed rename/substitution while Conda was using it.'
            $pipInstallerRejected = $false
            try {
                $null = Assert-CondaProjectManifestHasNoExternalInstallers `
                    -CondaExe $realCondaExe -Context $pipContext
            }
            catch { $pipInstallerRejected = $_.Exception.Message -match 'external installer.*pip' }
            Assert-True $pipInstallerRejected 'Conda''s real YAML parser did not reject a PROJECT pip installer section.'
        }
        finally { Close-CondaProjectExecutionContext $pipContext }
        Assert-True (-not (Get-LiteralWindowsNamespaceEntry -Path $heldCondarcPath)) 'Held minimal CONDARC survived exact cleanup.'

        $variablesManifest = Join-Path $claimCase 'parser-variables-environment.yml'
        [IO.File]::WriteAllText($variablesManifest,
            "name: audit`nchannels:`n  - https://conda.anaconda.org/conda-forge`n  - nodefaults`ndependencies:`n  - python=3.12`nvariables:`n  AUDIT_FLAG: hidden`n",
            (New-Object Text.UTF8Encoding($false)))
        $variablesContext = New-CondaProjectExecutionContext -ManifestPath $variablesManifest
        $variablesCondarcPath = $variablesContext.CondarcPath
        try {
            $manifestVariablesRejected = $false
            try {
                $null = Assert-CondaProjectManifestHasNoExternalInstallers `
                    -CondaExe $realCondaExe -Context $variablesContext
            }
            catch { $manifestVariablesRejected = $_.Exception.Message -match 'direct interpreter.*AUDIT_FLAG' }
            Assert-True $manifestVariablesRejected `
                'PROJECT variables that direct interpreter execution cannot apply were accepted.'
        }
        finally { Close-CondaProjectExecutionContext $variablesContext }
        Assert-True (-not (Get-LiteralWindowsNamespaceEntry -Path $variablesCondarcPath)) 'Second held minimal CONDARC survived exact cleanup.'

        $syntaxProbe = "import ast,sys,tokenize; f=tokenize.open(sys.argv[1]); s=f.read(); f.close(); ast.parse(s, filename=sys.argv[1])"
        $bomScriptPath = Join-Path $claimCase 'bom-script.py'
        $bomScriptBody = (New-Object Text.UTF8Encoding($false)).GetBytes("value = 'ok'`n")
        $bomScriptBytes = New-Object byte[] ($bomScriptBody.Length + 3)
        $bomScriptBytes[0] = 0xEF; $bomScriptBytes[1] = 0xBB; $bomScriptBytes[2] = 0xBF
        [Array]::Copy($bomScriptBody, 0, $bomScriptBytes, 3, $bomScriptBody.Length)
        [IO.File]::WriteAllBytes($bomScriptPath, $bomScriptBytes)
        Invoke-NativeChecked { & $realCondaPython -c $syntaxProbe $bomScriptPath } 'UTF-8 BOM script syntax probe'
        $pep263ScriptPath = Join-Path $claimCase 'pep263-script.py'
        [IO.File]::WriteAllBytes($pep263ScriptPath,
            [Text.Encoding]::GetEncoding(1252).GetBytes("# -*- coding: cp1252 -*-`nvalue = 'caf$([char]0x00E9)'`n"))
        Invoke-NativeChecked { & $realCondaPython -c $syntaxProbe $pep263ScriptPath } 'PEP 263 script syntax probe'
        $realVenv = Join-Path $claimCase 'real-venv'
        Invoke-NativeChecked { & $realCondaPython -m venv $realVenv } 'real Windows venv fixture'
        $realVenvIdentity = Get-ExistingPythonEnvironmentIdentity $realVenv
        Assert-True ($realVenvIdentity.Kind -ceq 'venv' -and
            $realVenvIdentity.PythonExe -ieq (Join-Path $realVenv 'Scripts\python.exe')) 'A real Windows venv was not identified through Scripts\python.exe.'
        $junction = Join-Path $claimCase 'python-junction'
        New-Item -ItemType Junction -Path $junction -Target $realCondaRoot | Out-Null
        try {
            $junctionRejected = $false
            try { $null = Assert-CondaEnvironmentPython -EnvPath $junction }
            catch { $junctionRejected = $_.Exception.Message -match 'reparse point' }
            Assert-True $junctionRejected 'Python health check accepted a junction-swapped environment prefix.'
        }
        finally { if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) } }
    }
}
finally { Remove-TestTree $claimCase }

$condaCommand = Get-Command conda.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($condaCommand) {
    $detectionBlock = [regex]::Match(
        $skillText,
        '(?ms)^```powershell\r?\n(?<code>\$candidates = @\(.*?)(?=^```\s*$)'
    )
    Assert-True $detectionBlock.Success 'Could not extract the documented conda-detection block.'
    $oldCondaExe = $env:CONDA_EXE
    $oldFunction = Get-Item Function:\conda -ErrorAction SilentlyContinue
    try {
        $env:CONDA_EXE = $condaCommand.Path
        Set-Item Function:\conda -Value { 'simulated conda-init function' }
        $ToolsRoot = 'Z:\intentionally-missing-tools-root'
        $null = . ([scriptblock]::Create($detectionBlock.Groups['code'].Value))
        Assert-True ($CondaExe -ieq $condaCommand.Path) 'Conda detection failed when Get-Command conda resolves to a PowerShell function.'
    }
    finally {
        if ($null -eq $oldCondaExe) { Remove-Item Env:\CONDA_EXE -ErrorAction SilentlyContinue }
        else { $env:CONDA_EXE = $oldCondaExe }
        Remove-Item Function:\conda -ErrorAction SilentlyContinue
        if ($oldFunction) { Set-Item Function:\conda -Value $oldFunction.ScriptBlock }
    }
} else {
    Write-Warning 'conda.exe not found; documented conda-init function detection test skipped.'
}
Remove-Item Function:\Invoke-NativeCaptured -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-NativeChecked -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-ProcessCapturedChecked -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-CondaProjectChild -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-CondaProjectEnvironmentCreate -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-CondaEnvironmentCreate -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-WithManagedEnvironmentMarkerProtection -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaProjectEnvironmentPreview -ErrorAction SilentlyContinue
Remove-Item Function:\Invoke-CondaEnvironmentYamlExport -ErrorAction SilentlyContinue
Remove-Item Function:\New-CondaProjectExecutionContext -ErrorAction SilentlyContinue
Remove-Item Function:\Close-CondaProjectExecutionContext -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-HeldTemporaryFile -ErrorAction SilentlyContinue
Remove-Item Function:\Get-OpenFileStreamSha256 -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaPlanState -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-RedactedCondaPlanSource -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaJsonPropertyValue -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertFrom-CondaChannelObject -ErrorAction SilentlyContinue
Remove-Item Function:\Resolve-CondaPlannedChannel -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaProjectPlanPreviewState -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaProjectApprovalFingerprint -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaInstalledChannelSources -ErrorAction SilentlyContinue
Remove-Item Function:\Set-CondaYamlChannelPolicy -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-CondaYamlMachineMetadata -ErrorAction SilentlyContinue
Remove-Item Function:\Get-IsolatableProjectManifestChannels -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-WindowsNativeArgument -ErrorAction SilentlyContinue
Remove-Item Function:\Resolve-ValidatedCondaExecutable -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-ExactPythonInterpreter -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-CondaEnvironmentPython -ErrorAction SilentlyContinue
Remove-Item Function:\Get-ExistingPythonEnvironmentIdentity -ErrorAction SilentlyContinue
Remove-Item Function:\Write-CondaEnvironmentManifestAtomic -ErrorAction SilentlyContinue
Remove-Item Function:\Get-CondaEnvironmentManifestState -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-NormalizedCondaManifestText -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-NoCondaManifestTransactionResidue -ErrorAction SilentlyContinue
Remove-Item Function:\Enter-CondaManifestMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Exit-CondaManifestMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-CondaEnvironmentCreationApproval -ErrorAction SilentlyContinue
Remove-Item Function:\New-CondaEnvironmentCreationApproval -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-SimpleCondaPackageSpec -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-SimplePipPackageSpec -ErrorAction SilentlyContinue
Remove-Item Function:\Get-OwnedStandaloneEnvironment -ErrorAction SilentlyContinue
Remove-Item Function:\Write-StandaloneEnvironmentIdentity -ErrorAction SilentlyContinue
Remove-Item Function:\Get-StableStandaloneEnvironmentPath -ErrorAction SilentlyContinue
Remove-Item Function:\Resolve-StandaloneScriptPath -ErrorAction SilentlyContinue
Remove-Item Function:\Get-ManagedEnvironmentRecoveryClaim -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-OwnedManagedCondaEnv -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-OwnedTempCondaEnv -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-OwnedEnvironmentDirectoryKeepingMarkerLast -ErrorAction SilentlyContinue
Remove-Item Function:\New-ManagedEnvironmentClaim -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-ManagedEnvironmentClaim -ErrorAction SilentlyContinue
Remove-Item Function:\Remove-ManagedEnvironmentClaim -ErrorAction SilentlyContinue
Remove-Item Function:\Enter-ManagedEnvironmentMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Exit-ManagedEnvironmentMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Protect-ProjectCondaGitIgnore -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-GitIgnoreLiteralPattern -ErrorAction SilentlyContinue
Remove-Item Function:\Add-GitIgnoreRuleAtomic -ErrorAction SilentlyContinue
Remove-Item Function:\Undo-GitIgnoreRuleAtomic -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-MinicondaObservedPathState -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-NoMinicondaGitIgnoreResidue -ErrorAction SilentlyContinue
Remove-Item Function:\Enter-MinicondaGitIgnoreMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Exit-MinicondaGitIgnoreMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Write-MinicondaRuntimeConfig -ErrorAction SilentlyContinue
Remove-Item Function:\Get-MinicondaRuntimeConfigState -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-NoMinicondaRuntimeConfigResidue -ErrorAction SilentlyContinue
Remove-Item Function:\Enter-MinicondaConfigMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Exit-MinicondaConfigMutex -ErrorAction SilentlyContinue
Remove-Item Function:\Get-StablePathState -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-StablePathState -ErrorAction SilentlyContinue
Remove-Item Function:\Resolve-ConfiguredPath -ErrorAction SilentlyContinue
Remove-Item Function:\Resolve-SafeLiteralWindowsPath -ErrorAction SilentlyContinue
Remove-Item Function:\Assert-NoReparseInExistingPath -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-Sha256Hex -ErrorAction SilentlyContinue
Remove-Item Function:\ConvertTo-CanonicalWindowsPath -ErrorAction SilentlyContinue
Remove-Item Function:\Get-FileByteState -ErrorAction SilentlyContinue

Write-Host '[7/7] Optional isolated Claude Code marketplace/install round trip'
$claude = Get-Command claude -ErrorAction SilentlyContinue
if ($claude) {
    $claudeConfig = Join-Path ([IO.Path]::GetTempPath()) ('cc-mini-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $claudeEnv = @{ CLAUDE_CONFIG_DIR = $claudeConfig }
    $claudePath = if ($claude.Path) { $claude.Path } elseif ($claude.Source) { $claude.Source } else { $claude.Definition }
    $claudeLiteral = ConvertTo-PowerShellLiteral $claudePath
    $repoLiteral = ConvertTo-PowerShellLiteral $RepoRoot
    try {
        $addMarket = Invoke-RedirectedPowerShell "& $claudeLiteral plugin marketplace add $repoLiteral" $claudeEnv
        Assert-True ($addMarket.ExitCode -eq 0) "Claude marketplace add failed: $($addMarket.Output)"
        $install = Invoke-RedirectedPowerShell "& $claudeLiteral plugin install 'miniconda-python-env@miniconda-python-env'" $claudeEnv
        Assert-True ($install.ExitCode -eq 0) "Claude plugin install failed: $($install.Output)"
        $list = Invoke-RedirectedPowerShell "& $claudeLiteral plugin list" $claudeEnv
        Assert-True ($list.ExitCode -eq 0) "Claude plugin list failed: $($list.Output)"
        Assert-True ($list.Output -match 'miniconda-python-env') 'Claude plugin list does not contain miniconda-python-env.'
        Assert-True ($list.Output -match [regex]::Escape($topVersion)) "Claude plugin list does not report version $topVersion."
        Assert-True ($list.Output -notmatch '(?i)failed to load|load failed') "Claude reports a failed plugin load: $($list.Output)"
    }
    finally { Remove-TestTree $claudeConfig }
} else {
    Write-Warning 'Claude CLI not found; isolated Claude install/load test skipped.'
}

Write-Host "miniconda-python-env verification passed (description: $descBytes bytes; skill: $skillLines lines)."
