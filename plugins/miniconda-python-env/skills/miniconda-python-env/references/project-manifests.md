# PROJECT previews and safe conda manifests

Read this file in full before previewing or creating a PROJECT environment from
`environment.yml`, or before exporting any kept conda environment.

## Preview a PROJECT manifest

Require `nodefaults` plus only official `conda-forge` or absolute HTTPS channel
URLs for the minimal child-only `CONDARC`. If classification fails, stop unless
the user explicitly authorizes an inherited-policy preview. Never silently
switch policy, remap sources, accept channel terms, or permit a pip section.
Also reject `variables:`: this skill runs direct interpreter paths without
activation, so conda activation variables would not reach the task process.

```powershell
$UseInheritedProjectConfig = $UseInheritedProjectConfig -eq $true
if (-not $UseInheritedProjectConfig) {
    $null = Get-IsolatableProjectManifestChannels $ManifestPath
}
$ProjectPreview = Get-CondaProjectEnvironmentPreview -CondaExe $CondaExe `
    -EnvPath $EnvPath -ManifestPath $ManifestPath `
    -UseInheritedConfiguration:$UseInheritedProjectConfig
$ProjectApprovalJson = $ProjectPreview | Select-Object ManifestPath, EnvPath, CondaExe, `
    UseInheritedConfiguration, ResolvedSources, PlannedChannels, VariableNames, `
    PythonVersion, PythonMajorMinor, PackageCount, ManifestFingerprint, PlanFingerprint, `
    ChannelConfigurationFingerprint, ApprovalFingerprint | ConvertTo-Json -Depth 10
$ProjectApprovalJson
```

Show that exact JSON and wait for confirmation. In a later turn/process,
reconstruct `$ProjectPreview` from unchanged approved JSON; never rerun a preview
and silently approve changed values. The create helper rechecks the manifest,
configuration, and solve fingerprints. This does not make remote packages
immutable; use reviewed `conda-lock` output when that guarantee matters.

Default-channel access may require acceptance; `conda-anaconda-tos` entered
installers on 2025-07-15. Never accept terms for the user. Miniconda installation
itself is not governed by Anaconda channel terms.

## Export and commit a kept conda manifest

Use the same isolated or explicitly approved inherited policy. Do not export a
venv or manager-owned environment through conda.

```powershell
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    if ($Lifecycle -eq 'PROJECT') {
        $ManifestPath = Join-Path $ProjectRoot 'environment.yml'
    } else {
        throw 'Choose an absolute companion environment.yml path for this STANDALONE env.'
    }
}
$exportArgs = @{
    CondaExe = $CondaExe
    EnvPath = $EnvPath
    ChannelPolicy = $ChannelPolicy
}
if ($ChannelPolicy -like 'project-*') {
    $exportArgs.ManifestPath = $ManifestPath
    $exportArgs.ApprovedPreview = $ProjectPreview
}
$yaml = Invoke-CondaEnvironmentYamlExport @exportArgs
$manifestState = Get-CondaEnvironmentManifestState $ManifestPath
```

If the current content differs after line-ending normalization, show a concise
diff and ask the user to choose `Replace`, `SaveGenerated`, or `KeepExisting`.
An absent or equivalent manifest needs no extra overwrite prompt. Pass the exact
observed state into the mutex-protected CAS writer:

```powershell
$manifestDiffers = $manifestState.Kind -ceq 'File' -and
    (ConvertTo-NormalizedCondaManifestText $manifestState.Content) -cne
    (ConvertTo-NormalizedCondaManifestText $yaml)
if ($manifestDiffers) {
    $ManifestAction = $null
    # Show the diff, ask the user, and set ManifestAction only to the exact
    # confirmed Replace, SaveGenerated, or KeepExisting choice.
    if ($ManifestAction -notin @('Replace', 'SaveGenerated', 'KeepExisting')) {
        throw 'A differing environment.yml requires an explicit overwrite choice.'
    }
} else {
    # Replace is the writer's idempotent action for an absent/equivalent file;
    # it creates the missing file and writes nothing for equivalent content.
    $ManifestAction = 'Replace'
}
$result = Write-CondaEnvironmentManifestAtomic -Path $ManifestPath -Yaml $yaml `
    -ExpectedState $manifestState -Action $ManifestAction
$result
```

`Replace` performs a same-directory atomic replacement and retains a timestamped
backup of different old bytes. `SaveGenerated` writes a non-colliding companion.
`KeepExisting` writes nothing. If the manifest changes after observation, stop,
show the new diff, and confirm again. The helper removes owned staging files;
transaction residue causes later operations to fail closed.

Offer `--from-history` only when requested and explain that it omits resolved
transitive packages. The export helper rejects credentials, environment
variables, pip subsections, editable/direct URLs, and machine-local paths;
write separately reviewed requirements/lock data for pip packages. It removes
top-level `prefix:` and rooted prefix `name:` metadata; audits installed package sources;
and emits BOM-less UTF-8 with the approved channel policy.
