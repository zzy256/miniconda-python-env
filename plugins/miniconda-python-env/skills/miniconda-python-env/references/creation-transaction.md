# Environment creation transaction

Read this file in full whenever creating a conda environment.

## Transaction boundary

Use direct interpreter paths rather than activation. Keep creation, bootstrap,
task execution, and TEMP cleanup inside this one outer boundary:

```powershell
try {
    $PrefixLock = Enter-ManagedEnvironmentMutex -EnvPath $EnvPath
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $EnvPath
    if (Test-Path -LiteralPath $EnvPath) {
        throw "Environment path appeared while waiting for its prefix lock: $EnvPath"
    }
    if ($Lifecycle -eq 'PROJECT') {
        $GitIgnoreTransaction = Protect-ProjectCondaGitIgnore `
            -ProjectRoot $ProjectRoot -EnvPath $EnvPath
    }
    if (-not ($Lifecycle -eq 'PROJECT' -and $ManifestPath)) {
        $LockedCreationPlan = Assert-CondaEnvironmentCreationApproval `
            -ApprovedPlan $NoManifestApproval -Lifecycle $Lifecycle `
            -ManagedRoot $ManagedRoot -EnvPath $EnvPath -CondaExe $CondaExe `
            -PythonVersion $PythonVersion -ChannelPolicy isolated-conda-forge `
            -CondaPackages $CondaPackages -PipPackages $PipPackages
    }
    $CreationClaim = New-ManagedEnvironmentClaim -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $EnvPath
    if ($Lifecycle -eq 'PROJECT' -and $ManifestPath) {
        $CreationAttempted = $true
        $null = Invoke-CondaProjectEnvironmentCreate -CondaExe $CondaExe `
            -EnvPath $EnvPath -ManifestPath $ManifestPath `
            -ApprovedPreview $ProjectPreview -Lifecycle $Lifecycle `
            -ManagedRoot $ManagedRoot -Claim $CreationClaim
        $PythonExe = Assert-CondaEnvironmentPython -EnvPath $EnvPath `
            -ExpectedMajorMinor $ProjectPreview.PythonMajorMinor
        $ChannelPolicy = if ($ProjectPreview.UseInheritedConfiguration) {
            'project-inherited'
        } else { 'project-isolated' }
    } else {
        $CreationAttempted = $true
        $createResult = Invoke-CondaEnvironmentCreate `
            -CondaExe $LockedCreationPlan.CondaExe `
            -EnvPath $LockedCreationPlan.EnvPath `
            -PythonVersion $LockedCreationPlan.PythonVersion `
            -Lifecycle $LockedCreationPlan.Lifecycle `
            -ManagedRoot $LockedCreationPlan.ManagedRoot -Claim $CreationClaim
        $PythonExe = $createResult.PythonExe
        $ChannelPolicy = 'isolated-conda-forge'
    }
    $CreatedThisInvocation = $true
    $EnvKind = 'conda'
    # Run SKILL.md Section 5 here. Its no-manifest helpers take only
    # LockedCreationPlan + CreationClaim, never ambient path/version/package variables.
    if ($Lifecycle -ne 'TEMP') {
        if ($Lifecycle -eq 'STANDALONE') {
            if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
                throw "Save the STANDALONE script before finalizing its identity: $ScriptPath"
            }
            Invoke-NativeChecked { & $PythonExe -c `
                "import ast,sys,tokenize; f=tokenize.open(sys.argv[1]); s=f.read(); f.close(); ast.parse(s, filename=sys.argv[1])" `
                $ScriptPath } 'STANDALONE script syntax probe'
            $null = Write-StandaloneEnvironmentIdentity -Claim $CreationClaim `
                -TempEnvRoot $TempEnvRoot -EnvPath $EnvPath -ScriptPath $ScriptPath
        }
        Remove-ManagedEnvironmentClaim -Claim $CreationClaim `
            -Lifecycle $Lifecycle -EnvPath $EnvPath
        $CreationClaim = $null
        Exit-ManagedEnvironmentMutex $PrefixLock
        $PrefixLock = $null
    }
    if ($Lifecycle -eq 'STANDALONE') {
        Invoke-NativeChecked { & $PythonExe $ScriptPath } 'Python task'
    } elseif ($PythonTaskCommand -is [scriptblock]) {
        Invoke-NativeChecked $PythonTaskCommand 'Python task'
    } else {
        throw 'Define a task-specific checked PythonTaskCommand (script, module, pytest, inline code, or verification probe).'
    }
}
catch {
    $PrimaryError = $_
    try { if ($Lifecycle -ne 'TEMP' -and $CreationClaim -and -not $CreatedThisInvocation) {
        Remove-OwnedManagedCondaEnv -Lifecycle $Lifecycle -ManagedRoot $ManagedRoot `
            -EnvPath $EnvPath -CondaExe $CondaExe -Claim $CreationClaim
        $CreationClaim = $null
        if ($Lifecycle -eq 'PROJECT' -and $GitIgnoreTransaction) {
            Undo-GitIgnoreRuleAtomic $GitIgnoreTransaction
            $GitIgnoreTransaction = $null
        }
    } elseif ($Lifecycle -ne 'TEMP' -and $CreationClaim) {
        Write-Warning "Bootstrap failed after a healthy kept env was created; preserve prefix and claim for recovery: $EnvPath | $($CreationClaim.Path)"
    } elseif (-not $CreationClaim -and $Lifecycle -eq 'PROJECT' -and
        $GitIgnoreTransaction -and -not (Test-Path -LiteralPath $EnvPath)) {
        Undo-GitIgnoreRuleAtomic $GitIgnoreTransaction
        $GitIgnoreTransaction = $null
    } } catch { $CleanupErrors.Add($_) }
}
finally {
    try {
        if ($Lifecycle -eq 'TEMP' -and $CreationAttempted -and $CreationClaim) {
            Remove-OwnedTempCondaEnv -TempEnvRoot $TempEnvRoot -EnvPath $EnvPath `
                -EnvName $EnvName -CondaExe $CondaExe -Claim $CreationClaim
            $CreationClaim = $null
        }
    } catch { $CleanupErrors.Add($_) }
    try { if ($PrefixLock) { Exit-ManagedEnvironmentMutex $PrefixLock } }
    catch { $CleanupErrors.Add($_) }
}
if ($PrimaryError -and $CleanupErrors.Count) {
    throw "Operation failed: $($PrimaryError.Exception.Message) Cleanup also failed: $($CleanupErrors.Exception.Message -join ' | ')"
}
if ($CleanupErrors.Count) { throw $CleanupErrors[0] }
if ($PrimaryError) { throw $PrimaryError }
```

## Cleanup contract

Run the TEMP cleanup in `finally` after any creation attempt. Delete only when
this invocation still owns the exact sibling claim and the exact environment is
a direct child of `$TempEnvRoot` whose leaf equals `$EnvName`. Use
`Remove-OwnedTempCondaEnv`; never delete a root, parent, reused env, or other env.
The cleanup helper uses an isolated offline conda removal before owned filesystem
cleanup, so unrelated `.condarc` channels or terms cannot block it. Report and
preserve the exact residual path and claim on failure; never accept terms merely
to delete an isolated TEMP environment.
