#Requires -Version 5.0

<#
.SYNOPSIS
Pre-configure paths and install the complete skill directory.

.PARAMETER TempEnvRoot
Root for temporary and standalone Python environments.

.PARAMETER ToolsRoot
Root used if the sister skill installs Miniconda.

.PARAMETER Agent
claude, codex, or both.

.PARAMETER Force
Replace existing config and skill directories without prompting.

.PARAMETER NonInteractive
Fail instead of prompting. Redirected stdin enables this automatically.
#>

[CmdletBinding()]
param(
    [string]$TempEnvRoot,
    [string]$ToolsRoot,
    [ValidateSet('claude', 'codex', 'both')]
    [string]$Agent = 'both',
    [switch]$Force,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

function Test-MinicondaPythonEnvFaultInjectionEnabled {
    return $env:MINICONDA_PYTHON_ENV_TEST_MODE -ceq '1'
}

function Normalize-AbsoluteWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -cne $Path.Trim()) {
        throw "'$Path' cannot begin or end with whitespace."
    }
    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -notmatch '^[A-Za-z]:[\\/]') {
        throw "'$Path' must be an absolute Windows path such as C:\Tools or C:\."
    }
    if ($candidate -match '[;"%<>|?*]' -or $candidate -match '[\x00-\x1f]' -or
        ($candidate.Length -gt 2 -and $candidate.Substring(2).Contains(':'))) {
        throw "'$Path' contains characters that are unsafe in a managed Windows path."
    }

    $normalizedCandidate = $candidate.Replace('/', '\')
    foreach ($component in @($normalizedCandidate.Substring(3) -split '\\' | Where-Object { $_ })) {
        if ($component -match '[. ]$') {
            throw "'$Path' contains a path component ending in a dot or space."
        }
        $deviceBase = (($component -split '\.', 2)[0]).TrimEnd(' ', '.')
        if ($deviceBase -match '^(?i:CON|PRN|AUX|NUL|COM(?:[1-9]|\u00B9|\u00B2|\u00B3)|LPT(?:[1-9]|\u00B9|\u00B2|\u00B3)|CONIN\$|CONOUT\$|CLOCK\$)$') {
            throw "'$Path' contains reserved Windows device component '$component'."
        }
    }

    $full = [System.IO.Path]::GetFullPath($normalizedCandidate)
    $driveRoot = [System.IO.Path]::GetPathRoot($full)
    if (-not [System.IO.Directory]::Exists($driveRoot)) {
        throw "'$Path' is on a drive that is not currently available: $driveRoot"
    }
    if ($full -match '^[A-Za-z]:\\$') { return $full }
    return $full.TrimEnd('\')
}

function Assert-DirectoryPathAvailable {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = [System.IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and -not (Test-Path -LiteralPath $current -PathType Container)) {
            throw "A file blocks required directory path: $current"
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Remove-InstalledPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    } else {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Read-ValidatedConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $null = Normalize-AbsoluteWindowsPath ([string]$cfg.temp_env_root)
        $null = Normalize-AbsoluteWindowsPath ([string]$cfg.tools_root)
        return $cfg
    }
    catch {
        throw "Existing config is invalid: $Path ($($_.Exception.Message))"
    }
}

function Confirm-Replacement {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][bool]$NonInteractiveMode
    )

    if ($Force) { return $true }
    if ($NonInteractiveMode) {
        throw "$Description already exists. Re-run with -Force or use an interactive terminal."
    }
    $answer = Read-Host "$Description already exists. Replace it? [y/N]"
    return $answer -in @('y', 'Y')
}

function Test-InjectedFailureBeforeBackup {
    param([Parameter(Mandatory = $true)][int]$Operation)

    $requested = 0
    return ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        [int]::TryParse($env:MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_BEFORE_BACKUP_OPERATION, [ref]$requested) -and
        $requested -eq $Operation)
}

function Enter-SetupMutex {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        $env:MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_NAME) {
        $env:MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_NAME
    } else {
        "Global\miniconda-python-env-setup-$sid"
    }
    $timeoutSeconds = 30
    $requestedTimeout = 0
    if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        [int]::TryParse($env:MINICONDA_PYTHON_ENV_SETUP_TEST_MUTEX_TIMEOUT_SECONDS, [ref]$requestedTimeout) -and
        $requestedTimeout -ge 1 -and $requestedTimeout -le 300) {
        $timeoutSeconds = $requestedTimeout
    }

    $mutex = New-Object Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($timeoutSeconds))
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning "Recovered abandoned setup lock '$name'. Destination state will be revalidated."
        }
        if (-not $acquired) {
            throw "Timed out waiting for another setup process to finish (lock '$name')."
        }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Assert-NoSetupTransactionResidue {
    param([Parameter(Mandatory = $true)][string[]]$CanonicalPaths)

    $residue = New-Object System.Collections.Generic.List[string]
    foreach ($canonicalPath in $CanonicalPaths) {
        $parent = Split-Path -Parent $canonicalPath
        $leaf = Split-Path -Leaf $canonicalPath
        if (Test-Path -LiteralPath $parent -PathType Container) {
            Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
                Where-Object { $_.Name -match ('^' + [regex]::Escape($leaf) + '\.(?:backup|staging)-[0-9a-f]{32}$') } |
                ForEach-Object { $residue.Add($_.FullName) }
        }
    }
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^miniconda-python-env-stage-[0-9a-f]{32}$' } |
        ForEach-Object { $residue.Add($_.FullName) }
    if ($residue.Count -gt 0) {
        throw "Unresolved setup transaction residue requires manual recovery: $($residue -join ' | ')"
    }
}

function Assert-TransactionBackup {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not $Entry.Moved) { return }
    $null = Assert-StablePathState -Path $Entry.Backup `
        -ExpectedKind $Entry.ExpectedKind `
        -ExpectedFingerprint $Entry.ExpectedFingerprint `
        -Label "Transaction backup for $($Entry.Path)"
}

function Assert-TransactionCanonical {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not $Entry.MutationStarted) { return }
    if (-not $Entry.CommitRecorded -or
        [string]::IsNullOrWhiteSpace($Entry.ExpectedCommittedKind) -or
        [string]::IsNullOrWhiteSpace($Entry.ExpectedCommittedFingerprint)) {
        throw "Transaction canonical state was not fully recorded; preserving canonical, stage, and backup for manual recovery: $($Entry.Path)"
    }
    $null = Assert-StablePathState -Path $Entry.Path `
        -ExpectedKind $Entry.ExpectedCommittedKind `
        -ExpectedFingerprint $Entry.ExpectedCommittedFingerprint `
        -Label "Transaction canonical path $($Entry.Path)"
}

function Assert-TransactionStage {
    param([Parameter(Mandatory = $true)]$Entry)

    if (-not $Entry.StageCreated) { return }
    if (-not $Entry.StagePrepared) {
        throw "Transaction stage was created but not fully fingerprinted; preserving it for manual recovery: $($Entry.StagePath)"
    }
    $null = Assert-StablePathState -Path $Entry.StagePath `
        -ExpectedKind $Entry.ExpectedCommittedKind `
        -ExpectedFingerprint $Entry.ExpectedCommittedFingerprint `
        -Label "Transaction stage for $($Entry.Path)"
}

function New-OwnedTransactionDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransactionId,
        [Parameter(Mandatory = $true)]$CreatedDirectories
    )

    $full = [IO.Path]::GetFullPath($Path)
    Assert-NoReparseInExistingPath -Path $full -Name 'Setup destination path'
    $missing = New-Object System.Collections.Generic.List[string]
    $cursor = $full
    while (-not (Test-Path -LiteralPath $cursor)) {
        $missing.Add($cursor)
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
            throw "Could not find an existing parent for setup destination: $full"
        }
        $cursor = $parent
    }

    $anchor = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if (-not $anchor.PSIsContainer) {
        throw "A file blocks required setup directory path: $cursor"
    }
    if (($anchor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Setup destination path traverses reparse point '$cursor'."
    }

    for ($i = $missing.Count - 1; $i -ge 0; $i--) {
        $directory = $missing[$i]
        $parent = Split-Path -Parent $directory
        $leaf = Split-Path -Leaf $directory
        $ownedStage = Join-Path $parent (".$leaf.setup-parent-$TransactionId")
        if (Test-Path -LiteralPath $ownedStage) {
            throw "Setup parent staging path unexpectedly exists: $ownedStage"
        }
        [void][IO.Directory]::CreateDirectory($ownedStage)
        try {
            if (Test-Path -LiteralPath $directory) {
                throw "Setup destination directory appeared concurrently: $directory"
            }
            [IO.Directory]::Move($ownedStage, $directory)
        }
        catch {
            if (Test-Path -LiteralPath $ownedStage) {
                Remove-Item -LiteralPath $ownedStage -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
        $created = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $created.PSIsContainer -or
            ($created.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "New setup directory did not remain a real directory: $directory"
        }
        [void]$CreatedDirectories.Add($directory)
    }
}

function Remove-EmptyOwnedTransactionDirectories {
    param([Parameter(Mandatory = $true)]$CreatedDirectories)

    $errors = New-Object System.Collections.Generic.List[string]
    for ($i = $CreatedDirectories.Count - 1; $i -ge 0; $i--) {
        $directory = [string]$CreatedDirectories[$i]
        try {
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Owned setup parent changed type or became a reparse point; preserving it: $directory"
            }
            if (@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -ne 0) {
                continue
            }
            [IO.Directory]::Delete($directory, $false)
        }
        catch { $errors.Add("${directory}: $($_.Exception.Message)") }
    }
    return [string[]]$errors.ToArray()
}

function Invoke-TestCanonicalInvalidation {
    param(
        [Parameter(Mandatory = $true)][int]$Operation,
        [Parameter(Mandatory = $true)]$Entry
    )

    if (-not (Test-MinicondaPythonEnvFaultInjectionEnabled)) { return }
    $requested = 0
    if (-not [int]::TryParse($env:MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_OPERATION, [ref]$requested) -or
        $requested -ne $Operation -or -not $Entry.CommitRecorded) {
        return
    }
    switch ($env:MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_MODE) {
        'content' {
            if ($Entry.ExpectedCommittedKind -ceq 'Directory') {
                [IO.File]::WriteAllText(
                    (Join-Path $Entry.Path '.canonical-concurrent-write'),
                    'external',
                    (New-Object Text.UTF8Encoding($false))
                )
            } else {
                [IO.File]::AppendAllText($Entry.Path, 'external', [Text.Encoding]::ASCII)
            }
        }
        'type' {
            Remove-InstalledPath $Entry.Path
            if ($Entry.ExpectedCommittedKind -ceq 'Directory') {
                [IO.File]::WriteAllText($Entry.Path, 'external-file', [Text.Encoding]::ASCII)
            } else {
                [void][IO.Directory]::CreateDirectory($Entry.Path)
            }
        }
        default { throw 'MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_MODE must be content or type.' }
    }
    throw "Simulated concurrent canonical $($env:MINICONDA_PYTHON_ENV_SETUP_TEST_INVALIDATE_CANONICAL_MODE) mutation."
}

function Invoke-TestBackupMutation {
    param([Parameter(Mandatory = $true)]$Entry)

    if ($Entry.ExpectedKind -ceq 'Directory') {
        [IO.File]::WriteAllText(
            (Join-Path $Entry.Backup '.fingerprint-tamper'),
            'test-only fingerprint mutation',
            (New-Object Text.UTF8Encoding($false))
        )
    } else {
        [IO.File]::AppendAllText(
            $Entry.Backup,
            'test-only fingerprint mutation',
            (New-Object Text.UTF8Encoding($false))
        )
    }
}

$nonInteractiveMode = $NonInteractive -or [System.Console]::IsInputRedirected
$missing = @()
if ([string]::IsNullOrWhiteSpace($TempEnvRoot)) { $missing += '-TempEnvRoot' }
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) { $missing += '-ToolsRoot' }
if ($missing.Count -gt 0 -and $nonInteractiveMode) {
    throw "setup.ps1 cannot prompt because stdin is redirected/non-interactive; missing required path parameter(s): $($missing -join ', ')."
}

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host '  miniconda-python-env - pre-configured install' -ForegroundColor Cyan
Write-Host '==================================================================' -ForegroundColor Cyan

$defaultToolsRoot = if (Test-Path -LiteralPath 'D:\' -PathType Container) {
    'D:\Tools'
} else {
    Join-Path $env:USERPROFILE 'Tools'
}
$defaultTempEnvRoot = if (Test-Path -LiteralPath 'D:\' -PathType Container) {
    'D:\Projects\Claude\Temp'
} else {
    $localDataRoot = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Join-Path $env:USERPROFILE 'AppData\Local'
    } else {
        $env:LOCALAPPDATA
    }
    Join-Path $localDataRoot 'Claude\Temp'
}

if ([string]::IsNullOrWhiteSpace($TempEnvRoot)) {
    $answer = Read-Host "TempEnvRoot [default: $defaultTempEnvRoot]"
    $TempEnvRoot = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultTempEnvRoot } else { $answer }
}
if ([string]::IsNullOrWhiteSpace($ToolsRoot)) {
    $answer = Read-Host "ToolsRoot [default: $defaultToolsRoot]"
    $ToolsRoot = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultToolsRoot } else { $answer }
}

$TempEnvRoot = Normalize-AbsoluteWindowsPath $TempEnvRoot
$ToolsRoot = Normalize-AbsoluteWindowsPath $ToolsRoot

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillSourceDir = Join-Path $repoRoot 'skills\miniconda-python-env'
$requiredSkillFiles = @('SKILL.md', 'agents\openai.yaml', 'scripts\EnvironmentHelpers.ps1')
foreach ($relativeFile in $requiredSkillFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillSourceDir $relativeFile) -PathType Leaf)) {
        throw "Required skill resource '$relativeFile' not found under $skillSourceDir"
    }
}
$environmentHelpers = Join-Path $skillSourceDir 'scripts\EnvironmentHelpers.ps1'
. $environmentHelpers

$lock = Enter-SetupMutex
$configLock = $null
try {
$cfgDir = Join-Path $env:USERPROFILE '.config\claude-skills'
$cfgPath = Join-Path $cfgDir 'miniconda-python-env.json'
$targets = @()
if ($Agent -in @('claude', 'both')) {
    $targets += [PSCustomObject]@{ Agent = 'Claude Code'; Path = Join-Path $env:USERPROFILE '.claude\skills\miniconda-python-env' }
}
if ($Agent -in @('codex', 'both')) {
    $targets += [PSCustomObject]@{ Agent = 'Codex'; Path = Join-Path $env:USERPROFILE '.codex\skills\miniconda-python-env' }
}

$configLock = Enter-MinicondaConfigMutex $cfgPath
Assert-NoSetupTransactionResidue (@($cfgPath) + @($targets | ForEach-Object { $_.Path }))
Assert-NoMinicondaRuntimeConfigResidue $cfgPath

# Preflight every destination and every overwrite decision before the first write.
Assert-DirectoryPathAvailable $cfgDir
if ((Test-Path -LiteralPath $cfgPath) -and -not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
    throw "A directory blocks the config file path: $cfgPath"
}
foreach ($target in $targets) {
    Assert-DirectoryPathAvailable $target.Path
    if ((Test-Path -LiteralPath $target.Path) -and
        -not (Test-Path -LiteralPath $target.Path -PathType Container)) {
        throw "A file blocks the skill directory path: $($target.Path)"
    }
}

$writeConfig = $true
$existingConfigValid = $false
if (Test-Path -LiteralPath $cfgPath) {
    try {
        $existing = Read-ValidatedConfig $cfgPath
        $existingConfigValid = $true
        Write-Host "Existing config: temp_env_root=$($existing.temp_env_root); tools_root=$($existing.tools_root)" -ForegroundColor DarkGray
    }
    catch {
        Write-Warning $_.Exception.Message
    }
    $writeConfig = Confirm-Replacement -Description "Config $cfgPath" -NonInteractiveMode $nonInteractiveMode
    if (-not $writeConfig -and -not $existingConfigValid) {
        throw "The existing config is unusable and was not replaced. No changes were made: $cfgPath"
    }
}

$installTargets = @()
foreach ($target in $targets) {
    $replace = $true
    if (Test-Path -LiteralPath $target.Path) {
        $replace = Confirm-Replacement -Description "$($target.Agent) skill directory $($target.Path)" -NonInteractiveMode $nonInteractiveMode
    }
    if ($replace) { $installTargets += $target }
}

if (-not $writeConfig -and $installTargets.Count -eq 0) {
    Write-Host 'No changes made.' -ForegroundColor Yellow
    return
}

$transactionId = [guid]::NewGuid().ToString('N')
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("miniconda-python-env-stage-$transactionId")
$stageSkill = Join-Path $stageRoot 'skill'
$journal = New-Object System.Collections.Generic.List[object]
$createdDirectories = New-Object System.Collections.Generic.List[string]
$committedTargetCount = 0
$operationCount = 0
$preserveStageForRecovery = $false

try {
    $sourceState = Get-StablePathState $skillSourceDir
    if ($sourceState.Kind -cne 'Directory') {
        throw "Skill source is not a real directory: $skillSourceDir"
    }
    New-Item -ItemType Directory -Path $stageSkill -Force | Out-Null
    Get-ChildItem -LiteralPath $skillSourceDir -Force | Copy-Item -Destination $stageSkill -Recurse -Force
    if (-not (Test-Path -LiteralPath (Join-Path $stageSkill 'SKILL.md') -PathType Leaf)) {
        throw 'Staged skill validation failed.'
    }
    $sourceMutationMarker = $null
    if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        $env:MINICONDA_PYTHON_ENV_SETUP_TEST_MUTATE_SOURCE_DURING_STAGE -eq '1') {
        $sourceMutationMarker = Join-Path $skillSourceDir ".setup-source-mutation-$transactionId"
        [IO.File]::WriteAllText($sourceMutationMarker, 'external', [Text.Encoding]::ASCII)
    }
    try {
        $null = Assert-StablePathState -Path $stageSkill `
            -ExpectedKind $sourceState.Kind `
            -ExpectedFingerprint $sourceState.Fingerprint `
            -Label 'Staged skill source copy'
        $null = Assert-StablePathState -Path $skillSourceDir `
            -ExpectedKind $sourceState.Kind `
            -ExpectedFingerprint $sourceState.Fingerprint `
            -Label 'Skill source during setup staging'
    }
    finally {
        if ($sourceMutationMarker -and (Test-Path -LiteralPath $sourceMutationMarker -PathType Leaf)) {
            Remove-Item -LiteralPath $sourceMutationMarker -Force
        }
    }
    $stagedSkillState = Get-StablePathState $stageSkill

    if ($writeConfig) {
        New-OwnedTransactionDirectoryPath -Path $cfgDir -TransactionId $transactionId `
            -CreatedDirectories $createdDirectories
        $backup = "$cfgPath.backup-$transactionId"
        $sameDirectoryStage = "$cfgPath.staging-$transactionId"
        $entry = [PSCustomObject]@{
            Kind = 'File'; Path = $cfgPath; Backup = $backup; StagePath = $sameDirectoryStage
            WasExisting = (Test-Path -LiteralPath $cfgPath); Moved = $false; BackupCreated = $false
            MutationStarted = $false; CommitRecorded = $false; StageCreated = $false; StagePrepared = $false
            ExpectedKind = $null; ExpectedFingerprint = $null
            ExpectedCommittedKind = $null; ExpectedCommittedFingerprint = $null
        }
        $journal.Add($entry)
        $newConfigStage = [IO.File]::Open($sameDirectoryStage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $newConfigStage.Dispose()
        $entry.StageCreated = $true
        $configJson = @{ temp_env_root = $TempEnvRoot; tools_root = $ToolsRoot } | ConvertTo-Json
        [IO.File]::WriteAllText($sameDirectoryStage, $configJson, (New-Object Text.UTF8Encoding($false)))
        $null = Read-ValidatedConfig $sameDirectoryStage
        $stageState = Get-StablePathState $sameDirectoryStage
        if ($stageState.Kind -cne 'File') { throw "Config stage is not a file: $sameDirectoryStage" }
        $entry.ExpectedCommittedKind = $stageState.Kind
        $entry.ExpectedCommittedFingerprint = $stageState.Fingerprint
        $entry.StagePrepared = $true
        if (Test-InjectedFailureBeforeBackup ($operationCount + 1)) {
            throw "Simulated failure before backup for operation $($operationCount + 1)."
        }
        if ($entry.WasExisting) {
            $originalState = Get-StablePathState $cfgPath
            if ($originalState.Kind -cne $entry.Kind) {
                throw "Config path type changed before backup: $cfgPath"
            }
            $entry.ExpectedKind = $originalState.Kind
            $entry.ExpectedFingerprint = $originalState.Fingerprint
            [IO.File]::Move($cfgPath, $backup)
            $entry.Moved = $true
            $entry.BackupCreated = $true
            Assert-TransactionBackup $entry
        }
        Assert-TransactionStage $entry
        $entry.MutationStarted = $true
        [IO.File]::Move($sameDirectoryStage, $cfgPath)
        $entry.StageCreated = $false
        $entry.StagePrepared = $false
        $null = Assert-StablePathState -Path $cfgPath `
            -ExpectedKind $entry.ExpectedCommittedKind `
            -ExpectedFingerprint $entry.ExpectedCommittedFingerprint `
            -Label "Committed config $cfgPath"
        $entry.CommitRecorded = $true
        $null = Read-ValidatedConfig $cfgPath
        $operationCount++
        Invoke-TestCanonicalInvalidation -Operation $operationCount -Entry $entry
    }

    foreach ($target in $installTargets) {
        $parent = Split-Path -Parent $target.Path
        New-OwnedTransactionDirectoryPath -Path $parent -TransactionId $transactionId `
            -CreatedDirectories $createdDirectories
        $backup = "$($target.Path).backup-$transactionId"
        $sameDirectoryStage = "$($target.Path).staging-$transactionId"
        $entry = [PSCustomObject]@{
            Kind = 'Directory'; Path = $target.Path; Backup = $backup; StagePath = $sameDirectoryStage
            WasExisting = (Test-Path -LiteralPath $target.Path); Moved = $false; BackupCreated = $false
            MutationStarted = $false; CommitRecorded = $false; StageCreated = $false; StagePrepared = $false
            ExpectedKind = $null; ExpectedFingerprint = $null
            ExpectedCommittedKind = $null; ExpectedCommittedFingerprint = $null
        }
        $journal.Add($entry)
        [void][IO.Directory]::CreateDirectory($sameDirectoryStage)
        $entry.StageCreated = $true
        Get-ChildItem -LiteralPath $stageSkill -Force | Copy-Item -Destination $sameDirectoryStage -Recurse -Force
        $null = Assert-StablePathState -Path $sameDirectoryStage `
            -ExpectedKind $stagedSkillState.Kind `
            -ExpectedFingerprint $stagedSkillState.Fingerprint `
            -Label "Same-directory stage for $($target.Agent)"
        $entry.ExpectedCommittedKind = $stagedSkillState.Kind
        $entry.ExpectedCommittedFingerprint = $stagedSkillState.Fingerprint
        $entry.StagePrepared = $true
        if (Test-InjectedFailureBeforeBackup ($operationCount + 1)) {
            throw "Simulated failure before backup for operation $($operationCount + 1)."
        }
        if ($entry.WasExisting) {
            $originalState = Get-StablePathState $target.Path
            if ($originalState.Kind -cne $entry.Kind) {
                throw "Skill path type changed before backup: $($target.Path)"
            }
            $entry.ExpectedKind = $originalState.Kind
            $entry.ExpectedFingerprint = $originalState.Fingerprint
            [IO.Directory]::Move($target.Path, $backup)
            $entry.Moved = $true
            $entry.BackupCreated = $true
            Assert-TransactionBackup $entry
        }
        Assert-TransactionStage $entry
        $entry.MutationStarted = $true
        [IO.Directory]::Move($sameDirectoryStage, $target.Path)
        $entry.StageCreated = $false
        $entry.StagePrepared = $false
        $null = Assert-StablePathState -Path $target.Path `
            -ExpectedKind $entry.ExpectedCommittedKind `
            -ExpectedFingerprint $entry.ExpectedCommittedFingerprint `
            -Label "Committed skill for $($target.Agent)"
        $entry.CommitRecorded = $true
        if (-not (Test-Path -LiteralPath (Join-Path $target.Path 'SKILL.md') -PathType Leaf)) {
            throw "Installed skill validation failed for $($target.Agent)."
        }
        $committedTargetCount++
        $operationCount++
        Invoke-TestCanonicalInvalidation -Operation $operationCount -Entry $entry
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_SETUP_TEST_FAIL_AFTER_FIRST_TARGET -eq '1' -and
            $committedTargetCount -eq 1) {
            if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                $env:MINICONDA_PYTHON_ENV_SETUP_TEST_MUTATE_BACKUP_BEFORE_ROLLBACK -eq '1') {
                $firstMovedTarget = $journal | Where-Object {
                    $_.Kind -ceq 'Directory' -and $_.Moved
                } | Select-Object -First 1
                if ($firstMovedTarget) { Invoke-TestBackupMutation $firstMovedTarget }
            }
            throw 'Simulated post-commit failure for rollback verification.'
        }
    }

}
catch {
    $installError = $_.Exception.Message
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    $invalidStates = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $journal) {
        try {
            Assert-TransactionBackup $entry
            Assert-TransactionStage $entry
            Assert-TransactionCanonical $entry
        }
        catch {
            $invalidStates.Add([PSCustomObject]@{ Entry = $entry; Error = $_.Exception.Message })
        }
    }
    if ($invalidStates.Count -gt 0) {
        $preserveStageForRecovery = $true
        foreach ($invalid in $invalidStates) {
            $rollbackErrors.Add("$($invalid.Entry.Path): $($invalid.Error); canonical, staged, and backup copies were preserved")
        }
    } else {
        for ($i = $journal.Count - 1; $i -ge 0; $i--) {
            $entry = $journal[$i]
            try {
                Assert-TransactionBackup $entry
                Assert-TransactionStage $entry
                Assert-TransactionCanonical $entry
                if ($entry.MutationStarted) { Remove-InstalledPath $entry.Path }
                if ($entry.StageCreated) {
                    Remove-InstalledPath $entry.StagePath
                    $entry.StageCreated = $false
                    $entry.StagePrepared = $false
                }
                if ($entry.BackupCreated) {
                    if ($entry.Kind -ceq 'Directory') {
                        [IO.Directory]::Move($entry.Backup, $entry.Path)
                    } else {
                        [IO.File]::Move($entry.Backup, $entry.Path)
                    }
                    $entry.BackupCreated = $false
                    $entry.Moved = $false
                    $null = Assert-StablePathState -Path $entry.Path `
                        -ExpectedKind $entry.ExpectedKind `
                        -ExpectedFingerprint $entry.ExpectedFingerprint `
                        -Label "Restored transaction path $($entry.Path)"
                }
            }
            catch {
                if ($entry.Moved) { $preserveStageForRecovery = $true }
                $rollbackErrors.Add("$($entry.Path): $($_.Exception.Message)")
            }
        }
    }
    if ($preserveStageForRecovery) {
        $rollbackErrors.Add("Staged recovery copy was preserved: $stageRoot")
    } else {
        try { Remove-InstalledPath $stageRoot }
        catch { $rollbackErrors.Add("${stageRoot}: $($_.Exception.Message)") }
    }
    foreach ($parentError in @(Remove-EmptyOwnedTransactionDirectories $createdDirectories)) {
        $rollbackErrors.Add($parentError)
    }
    if ($rollbackErrors.Count -gt 0) {
        throw "Install failed and rollback was incomplete. Original error: $installError Rollback error(s): $($rollbackErrors -join ' | ')"
    }
    throw "Install failed; all committed changes were rolled back. $installError"
}

try {
    foreach ($entry in $journal) {
        Assert-TransactionStage $entry
        Assert-TransactionCanonical $entry
        if ($entry.BackupCreated) {
            Assert-TransactionBackup $entry
            Assert-TransactionCanonical $entry
            Assert-TransactionBackup $entry
            Remove-InstalledPath $entry.Backup
            $entry.BackupCreated = $false
            $entry.Moved = $false
        }
    }
    foreach ($entry in $journal) { Assert-TransactionCanonical $entry }
    Remove-InstalledPath $stageRoot
}
catch {
    throw "Install committed, but final ownership verification/backup cleanup failed; every surviving canonical, stage, and backup copy was preserved. $($_.Exception.Message)"
}

Write-Host ''
Write-Host "Install complete: config=$writeConfig; skill target(s)=$($installTargets.Count)." -ForegroundColor Green
Write-Host 'Restart Claude Code / Codex before using the skill.'
}
finally {
    try {
        if ($configLock) { Exit-MinicondaConfigMutex $configLock }
    }
    finally {
        try {
            if ($lock.Acquired) { $lock.Mutex.ReleaseMutex() }
        }
        finally { $lock.Mutex.Dispose() }
    }
}
