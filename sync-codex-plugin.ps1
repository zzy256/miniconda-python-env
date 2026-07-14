#Requires -Version 5.0

$ErrorActionPreference = 'Stop'

function Test-MinicondaPythonEnvFaultInjectionEnabled {
    return $env:MINICONDA_PYTHON_ENV_TEST_MODE -ceq '1'
}

function Enter-SyncMutex {
    param([Parameter(Mandatory = $true)][string]$CanonicalPath)

    $canonical = [IO.Path]::GetFullPath($CanonicalPath).TrimEnd('\').ToUpperInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)) }
    finally { $sha.Dispose() }
    $lockId = ([BitConverter]::ToString($hash)).Replace('-', '')
    $name = if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        $env:MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_NAME) {
        $env:MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_NAME
    } else {
        "Global\miniconda-python-env-snapshot-sync-$lockId"
    }
    $timeoutSeconds = 30
    $requestedTimeout = 0
    if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        [int]::TryParse($env:MINICONDA_PYTHON_ENV_SYNC_TEST_MUTEX_TIMEOUT_SECONDS, [ref]$requestedTimeout) -and
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
            Write-Warning "Recovered abandoned snapshot-sync lock '$name'."
        }
        if (-not $acquired) {
            throw "Timed out waiting for another snapshot synchronization process (lock '$name')."
        }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Assert-NoSyncResidue {
    param([Parameter(Mandatory = $true)][string]$Root)

    $residue = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^\.miniconda-python-env\.(?:stage|backup)-[0-9a-f]{32}$' })
    if ($residue.Count -gt 0) {
        throw "Unresolved snapshot transaction residue requires manual recovery: $($residue.FullName -join ' | ')"
    }
}

function Assert-SyncPathMatches {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedKind,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $null = Assert-StablePathState -Path $Path -ExpectedKind $ExpectedKind `
        -ExpectedFingerprint $ExpectedFingerprint -Label $Label
}

function Invoke-TestSyncCanonicalInvalidation {
    param(
        [Parameter(Mandatory = $true)][string]$CanonicalPath,
        [Parameter(Mandatory = $true)][string]$ExpectedKind
    )

    if (-not (Test-MinicondaPythonEnvFaultInjectionEnabled)) { return }
    switch ($env:MINICONDA_PYTHON_ENV_SYNC_TEST_INVALIDATE_CANONICAL_MODE) {
        '' { return }
        'content' {
            [IO.File]::WriteAllText(
                (Join-Path $CanonicalPath '.canonical-concurrent-write'),
                'external',
                (New-Object Text.UTF8Encoding($false))
            )
        }
        'type' {
            Remove-Item -LiteralPath $CanonicalPath -Recurse -Force
            if ($ExpectedKind -ceq 'Directory') {
                [IO.File]::WriteAllText($CanonicalPath, 'external-file', [Text.Encoding]::ASCII)
            } else {
                [void][IO.Directory]::CreateDirectory($CanonicalPath)
            }
        }
        default { throw 'MINICONDA_PYTHON_ENV_SYNC_TEST_INVALIDATE_CANONICAL_MODE must be content or type.' }
    }
    throw "Simulated concurrent canonical $($env:MINICONDA_PYTHON_ENV_SYNC_TEST_INVALIDATE_CANONICAL_MODE) mutation."
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$name = 'miniconda-python-env'
$environmentHelpers = Join-Path $repoRoot "skills\$name\scripts\EnvironmentHelpers.ps1"
if (-not (Test-Path -LiteralPath $environmentHelpers -PathType Leaf)) {
    throw "Required transaction helper is missing: $environmentHelpers"
}
. $environmentHelpers
$pluginsRoot = Join-Path $repoRoot 'plugins'
$snapshot = Join-Path $pluginsRoot $name
$id = [guid]::NewGuid().ToString('N')
$stage = Join-Path $pluginsRoot (".$name.stage-$id")
$backup = Join-Path $pluginsRoot (".$name.backup-$id")
$sourcePluginJson = Join-Path $repoRoot '.codex-plugin\plugin.json'
$sourceSkill = Join-Path $repoRoot "skills\$name"

$pluginsFull = [IO.Path]::GetFullPath($pluginsRoot).TrimEnd('\') + '\'
$snapshotFull = [IO.Path]::GetFullPath($snapshot).TrimEnd('\') + '\'
if (-not $snapshotFull.StartsWith($pluginsFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to synchronize outside plugins root: $snapshotFull"
}
if (-not (Test-Path -LiteralPath $sourcePluginJson -PathType Leaf)) {
    throw "Required Codex plugin manifest is missing: $sourcePluginJson"
}
if (-not (Test-Path -LiteralPath (Join-Path $sourceSkill 'SKILL.md') -PathType Leaf)) {
    throw "Required source skill is missing: $sourceSkill"
}

$lock = Enter-SyncMutex $snapshot
try {
    Assert-NoSyncResidue $pluginsRoot
    $backupCreated = $false
    $stageCreated = $false
    $stagePrepared = $false
    $canonicalMutationStarted = $false
    $canonicalCommitted = $false
    $preserveStageForRecovery = $false
    $backupExpectedKind = $null
    $backupExpectedFingerprint = $null
    $canonicalExpectedKind = $null
    $canonicalExpectedFingerprint = $null
    try {
        $sourcePluginState = Get-StablePathState $sourcePluginJson
        $sourceSkillState = Get-StablePathState $sourceSkill
        if ($sourcePluginState.Kind -cne 'File' -or $sourceSkillState.Kind -cne 'Directory') {
            throw 'Codex snapshot sources changed type before staging.'
        }

        [void][IO.Directory]::CreateDirectory($stage)
        $stageCreated = $true
        [void][IO.Directory]::CreateDirectory((Join-Path $stage '.codex-plugin'))
        [void][IO.Directory]::CreateDirectory((Join-Path $stage 'skills'))
        Copy-Item -LiteralPath $sourcePluginJson `
            -Destination (Join-Path $stage '.codex-plugin\plugin.json') -Force
        Copy-Item -LiteralPath $sourceSkill `
            -Destination (Join-Path $stage "skills\$name") -Recurse -Force
        Assert-SyncPathMatches -Path (Join-Path $stage '.codex-plugin\plugin.json') `
            -ExpectedKind $sourcePluginState.Kind -ExpectedFingerprint $sourcePluginState.Fingerprint `
            -Label 'Staged Codex plugin manifest'
        Assert-SyncPathMatches -Path (Join-Path $stage "skills\$name") `
            -ExpectedKind $sourceSkillState.Kind -ExpectedFingerprint $sourceSkillState.Fingerprint `
            -Label 'Staged source skill'
        $stagedState = Get-StablePathState $stage
        $canonicalExpectedKind = $stagedState.Kind
        $canonicalExpectedFingerprint = $stagedState.Fingerprint
        $stagePrepared = $true

        $sourceMutationMarker = $null
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_SYNC_TEST_MUTATE_SOURCE_DURING_STAGE -eq '1') {
            $sourceMutationMarker = Join-Path $sourceSkill ".sync-source-mutation-$id"
            [IO.File]::WriteAllText($sourceMutationMarker, 'external', [Text.Encoding]::ASCII)
        }
        try {
            Assert-SyncPathMatches -Path $sourcePluginJson `
                -ExpectedKind $sourcePluginState.Kind -ExpectedFingerprint $sourcePluginState.Fingerprint `
                -Label 'Codex plugin manifest source'
            Assert-SyncPathMatches -Path $sourceSkill `
                -ExpectedKind $sourceSkillState.Kind -ExpectedFingerprint $sourceSkillState.Fingerprint `
                -Label 'Skill source'
        }
        finally {
            if ($sourceMutationMarker -and (Test-Path -LiteralPath $sourceMutationMarker -PathType Leaf)) {
                Remove-Item -LiteralPath $sourceMutationMarker -Force
            }
        }

        if (Test-Path -LiteralPath $snapshot) {
            $snapshotState = Get-StablePathState $snapshot
            if ($snapshotState.Kind -cne 'Directory') {
                throw "Canonical snapshot is not a real directory: $snapshot"
            }
            $backupExpectedKind = $snapshotState.Kind
            $backupExpectedFingerprint = $snapshotState.Fingerprint
            [IO.Directory]::Move($snapshot, $backup)
            $backupCreated = $true
            Assert-SyncPathMatches -Path $backup -ExpectedKind $backupExpectedKind `
                -ExpectedFingerprint $backupExpectedFingerprint -Label 'Snapshot rollback backup'
        }
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_SYNC_TEST_FAIL_AFTER_BACKUP -eq '1') {
            throw 'Simulated sync failure after backing up the canonical snapshot.'
        }
        Assert-SyncPathMatches -Path $stage -ExpectedKind $canonicalExpectedKind `
            -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Prepared snapshot stage'
        $canonicalMutationStarted = $true
        [IO.Directory]::Move($stage, $snapshot)
        $stagePrepared = $false
        Assert-SyncPathMatches -Path $snapshot -ExpectedKind $canonicalExpectedKind `
            -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Committed canonical snapshot'
        $canonicalCommitted = $true

        Invoke-TestSyncCanonicalInvalidation -CanonicalPath $snapshot -ExpectedKind $canonicalExpectedKind
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_SYNC_TEST_MUTATE_BACKUP_BEFORE_ROLLBACK -eq '1' -and
            $backupCreated) {
            [IO.File]::WriteAllText(
                (Join-Path $backup '.fingerprint-tamper'),
                'test-only fingerprint mutation',
                (New-Object Text.UTF8Encoding($false))
            )
            throw 'Simulated sync failure after mutating the rollback backup.'
        }
    }
    catch {
        $failure = $_
        $recoveryErrors = New-Object System.Collections.Generic.List[string]
        $ownershipErrors = New-Object System.Collections.Generic.List[string]
        try {
            if ($backupCreated) {
                Assert-SyncPathMatches -Path $backup -ExpectedKind $backupExpectedKind `
                    -ExpectedFingerprint $backupExpectedFingerprint -Label 'Snapshot rollback backup'
            }
        } catch { $ownershipErrors.Add($_.Exception.Message) }
        try {
            if ($stagePrepared) {
                Assert-SyncPathMatches -Path $stage -ExpectedKind $canonicalExpectedKind `
                    -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Prepared snapshot stage'
            } elseif ($stageCreated -and -not $canonicalMutationStarted) {
                throw "Snapshot stage was not fully fingerprinted; preserving it for manual recovery: $stage"
            }
        } catch { $ownershipErrors.Add($_.Exception.Message) }
        try {
            if ($canonicalMutationStarted) {
                if (-not $canonicalCommitted) {
                    throw "Canonical snapshot mutation completed without a recorded fingerprint; preserving canonical and rollback backup: $snapshot"
                }
                Assert-SyncPathMatches -Path $snapshot -ExpectedKind $canonicalExpectedKind `
                    -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Committed canonical snapshot'
            } elseif ($backupCreated -and (Test-Path -LiteralPath $snapshot)) {
                throw "Canonical snapshot appeared concurrently after backup; preserving canonical and rollback backup: $snapshot"
            }
        } catch { $ownershipErrors.Add($_.Exception.Message) }

        if ($ownershipErrors.Count -gt 0) {
            $preserveStageForRecovery = $true
            foreach ($message in $ownershipErrors) { $recoveryErrors.Add($message) }
        } else {
            try {
                if ($canonicalMutationStarted) {
                    Remove-Item -LiteralPath $snapshot -Recurse -Force
                    $canonicalMutationStarted = $false
                    $canonicalCommitted = $false
                }
                if ($backupCreated) {
                    [IO.Directory]::Move($backup, $snapshot)
                    $backupCreated = $false
                    Assert-SyncPathMatches -Path $snapshot -ExpectedKind $backupExpectedKind `
                        -ExpectedFingerprint $backupExpectedFingerprint -Label 'Restored canonical snapshot'
                }
                if ($stagePrepared) {
                    Remove-Item -LiteralPath $stage -Recurse -Force
                    $stagePrepared = $false
                }
            }
            catch { $recoveryErrors.Add($_.Exception.Message) }
        }

        if ($preserveStageForRecovery) {
            $surviving = @($snapshot, $stage, $backup) | Where-Object { Test-Path -LiteralPath $_ }
            $recoveryErrors.Add("Preserved every current canonical/stage/backup copy for manual recovery: $($surviving -join ' | ')")
        }
        if ($recoveryErrors.Count -gt 0) {
            throw "Codex snapshot synchronization failed and recovery was incomplete. Original error: $($failure.Exception.Message) Recovery error(s): $($recoveryErrors -join ' | ')"
        }
        throw $failure
    }

    try {
        Assert-SyncPathMatches -Path $snapshot -ExpectedKind $canonicalExpectedKind `
            -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Committed canonical snapshot'
        if ($backupCreated) {
            Assert-SyncPathMatches -Path $backup -ExpectedKind $backupExpectedKind `
                -ExpectedFingerprint $backupExpectedFingerprint -Label 'Snapshot rollback backup'
            Assert-SyncPathMatches -Path $snapshot -ExpectedKind $canonicalExpectedKind `
                -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Committed canonical snapshot'
            Remove-Item -LiteralPath $backup -Recurse -Force
            $backupCreated = $false
        }
        Assert-SyncPathMatches -Path $snapshot -ExpectedKind $canonicalExpectedKind `
            -ExpectedFingerprint $canonicalExpectedFingerprint -Label 'Committed canonical snapshot'
    }
    catch {
        throw "Snapshot replacement committed, but final ownership verification/backup cleanup failed; surviving copies were preserved. $($_.Exception.Message)"
    }
    Write-Host 'Codex marketplace plugin snapshot synchronized exactly.'
}
finally {
    try {
        if ($lock.Acquired) { $lock.Mutex.ReleaseMutex() }
    }
    finally { $lock.Mutex.Dispose() }
}
