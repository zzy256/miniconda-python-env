---
name: miniconda-python-env
description: >-
  Use first for Python execution on Windows: running or writing scripts,
  installing project packages, building/testing a project, or choosing Python
  for data/OCR/automation. Also use to configure this skill's environment roots.
  Reuse existing .conda, .venv/venv, Poetry, uv, Pipenv, PDM, Pixi, Hatch, or Rye;
  create Miniconda only when none exists. Project pip/pytest work triggers this
  skill. One-offs are deleted; standalone scripts and project .conda envs are
  kept. Do not use for non-Python work, code-reading/conceptual questions,
  read-only interpreter locate/version/status checks, arbitrary deletion of
  user-managed envs, or persistent global/end-user CLI installation (including
  pipx intent); route the latter and missing Miniconda to windows-tools-install-manager.
---

# Miniconda-managed Python environments

This skill safely operates Python environments; discovery or reuse never implies ownership.

## 0. Load and validate configuration on every invocation

Config: `$env:USERPROFILE\.config\claude-skills\miniconda-python-env.json`
Set `$SkillRoot` to this skill directory, then load its helper before shared state:

```powershell
$helper = Join-Path $SkillRoot 'scripts\EnvironmentHelpers.ps1'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw "Required skill helper is missing: $helper"
}
# Temporarily relax only this process while loading the installed helper, then
# restore it immediately. Never change CurrentUser, LocalMachine, or Group Policy.
$priorProcessPolicy = Get-ExecutionPolicy -Scope Process
$changedProcessPolicy = $priorProcessPolicy -cne 'Bypass'
try {
    if ($changedProcessPolicy) {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    }
    . $helper
}
catch { throw "Cannot load the installed skill helper under the effective execution policy: $($_.Exception.Message)" }
finally {
    if ($changedProcessPolicy) {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy $priorProcessPolicy -Force -ErrorAction Stop
    }
}

$cfgPath = Join-Path $env:USERPROFILE '.config\claude-skills\miniconda-python-env.json'
$observedConfigState = Get-MinicondaRuntimeConfigState $cfgPath
$cfg = $null
if ($observedConfigState.Kind -ceq 'File') {
    try {
        $cfg = $observedConfigState.Content | ConvertFrom-Json
        $TempEnvRoot = Resolve-ConfiguredPath ([string]$cfg.temp_env_root) 'temp_env_root'
        $ToolsRoot = Resolve-ConfiguredPath ([string]$cfg.tools_root) 'tools_root'
    }
    catch {
        # Do not guess around malformed or stale config.
        $cfg = $null
        Write-Warning "miniconda-python-env config is invalid: $($_.Exception.Message)"
    }
} elseif ($observedConfigState.Kind -cne 'Absent') {
    throw "Runtime config path must be a regular file: $cfgPath"
}
```

If the file is missing or `$cfg` is invalid, stop and ask for both runtime paths:

- `TempEnvRoot`: temporary/standalone env parent; use `D:\Projects\Claude\Temp`
  when `D:\` is mounted, otherwise `$env:LOCALAPPDATA\Claude\Temp`.
- `ToolsRoot`: system-tool root shared with the sister skill; use `D:\Tools`
  when `D:\` is mounted, otherwise `$env:USERPROFILE\Tools`.

Accept `OK`/`默认` for those available-drive defaults or explicit absolute
paths. Validate them, then use the helper's mutex-protected atomic writer. Its
observed-state token prevents two first-use tasks from silently overwriting
conflicting choices:

```powershell
$TempEnvRoot = Resolve-ConfiguredPath $TempEnvRoot 'temp_env_root'
$ToolsRoot = Resolve-ConfiguredPath $ToolsRoot 'tools_root'
$null = Write-MinicondaRuntimeConfig -Path $cfgPath `
    -TempEnvRoot $TempEnvRoot -ToolsRoot $ToolsRoot `
    -ExpectedState $observedConfigState
$saved = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$TempEnvRoot = Resolve-ConfiguredPath ([string]$saved.temp_env_root) 'temp_env_root'
$ToolsRoot = Resolve-ConfiguredPath ([string]$saved.tools_root) 'tools_root'
```

Never continue with invalid config. Once valid, load it silently on later uses.

## 1. Keep trigger origin separate from lifecycle

Record two independent decisions:

### Trigger origin

- **EXPLICIT**: the user directly requested Python, a Python package, or a
  Python-based stack.
- **IMPLICIT**: the user requested an outcome and the agent chose Python (OCR,
  spreadsheet conversion, plotting, scraping, ML, automation, API, GUI, etc.).

Origin explains why this skill triggered. It never controls retention.

### Environment lifecycle

Apply the first matching rule:

| Lifecycle | Signal | Default path | End state |
|---|---|---|---|
| **PROJECT** | Ongoing project, existing repo, reusable build/test/helper code | `<project>\.conda` | Keep |
| **STANDALONE** | User wants a reusable script outside a project | `<TempEnvRoot>\<script-slug>-<script-path-hash>` | Keep |
| **TEMP** | One-off processing with no reuse | `<TempEnvRoot>\<task>-<timestamp>-<random>` | Delete only if created now |

Ask when genuinely ambiguous. A reusable Python build helper is PROJECT; a one-off command inside an unrelated repo is not automatically PROJECT.

## 2. Reuse before creation

Resolve the nearest project root deterministically and keep the Section 0 helper loaded:

```powershell
$ProjectRoot = Resolve-PythonProjectRoot -StartPath $WorkingPath
$ProjectManager = if ($ProjectRoot) { Get-ProjectPythonManager $ProjectRoot } else { $null }
```

Do not substitute the Git root when a nearer Python manifest exists. Pixi, Hatch,
Rye, Poetry, uv, Pipenv, PDM, and conda-lock own their environment workflow; a
manager conflict stops rather than falling through to generic conda creation.

Search in this order:

1. Interpreter explicitly supplied by the user/main agent or already used in
   this task.
2. A manager returned by `Get-ProjectPythonManager`. Resolve and use that
   manager's interpreter/environment even when it lives at `.venv` or `.conda`;
   use its sync/add/run/export workflow.
3. `<project>\.conda\python.exe`, only when no manager owns it.
4. `<project>\.venv\Scripts\python.exe`, then
   `<project>\venv\Scripts\python.exe`, only when no manager owns it.
5. Other project manifests: `environment.yml`, `environment.yaml`, or project
   configuration naming an interpreter. A manifest without an installed
   interpreter is a creation input, not an environment to claim as reused.
6. For STANDALONE, call `Get-OwnedStandaloneEnvironment -TempEnvRoot
   $TempEnvRoot -ScriptPath $ScriptPath`, then health-check its interpreter.
   Missing/tampered identity or an unfinished sibling claim is a hard stop.

A TEMP path includes a random suffix. A collision means choose a new path or stop; it is not proof of ownership and must never be deleted.

Set explicit state:

```powershell
$EnvKind = 'conda'       # or 'venv', 'uv', 'poetry', 'pipenv', 'pdm', 'pixi', 'hatch', 'rye'
$CreatedThisInvocation = $false
$ChannelPolicy = 'preserve'
```

For an explicit interpreter, run `Assert-ExactPythonInterpreter` immediately.
For a generic env candidate, use `Get-ExistingPythonEnvironmentIdentity`; names
never determine conda versus venv, and ambiguous/missing markers stop. Before
reusing an exact managed path, call `Get-ManagedEnvironmentRecoveryClaim`; any
claim means an unfinished transaction—do not treat it as ordinary reuse. With
approval, acquire its prefix mutex, reload and compare the claim under that lock,
then resume bootstrap and `Remove-ManagedEnvironmentClaim`, or discard through
`Remove-OwnedManagedCondaEnv`; never race recovery in two processes. Manager-owned
tools keep their workflow. Ask before migrating a system Python; never delete reuse.

For a reused PROJECT conda env, reclassify its current manifest before export:
safe public `nodefaults` means `project-isolated`; otherwise a fresh inherited
preview and user-approved record are mandatory. `preserve` is not a shortcut for
a PROJECT export because current global channels could leak into the manifest.

## 3. Find conda, or route Miniconda installation safely

Skip this section for a selected venv or manager-owned toolchain. Find conda only when actually required.

Use the loaded `Invoke-NativeChecked` for commands that require exit zero and
`Invoke-NativeCaptured` for expected-nonzero probes. The helper deliberately
separates stdout/stderr under Windows PowerShell 5.1, so harmless stderr cannot
terminate before exit-code capture or contaminate JSON/YAML stdout.

Detection:

```powershell
$candidates = @(
    ([IO.Path]::Combine($ToolsRoot, 'miniconda\Scripts\conda.exe')),
    $env:CONDA_EXE
)
$pathConda = Get-Command conda -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($pathConda) { $candidates += $pathConda.Path }
$existingCandidates = @($candidates |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Leaf) } |
    Select-Object -Unique)
$CondaExe = if ($existingCandidates.Count -gt 0) {
    # A present-but-invalid candidate is a hard failure, not permission to
    # install another distribution or silently fall through.
    Resolve-ValidatedCondaExecutable -Candidate $existingCandidates
} else { $null }
```

For PATH conda, run checked `info --json` and parse `root_prefix`. Respect a project-owned Anaconda env; ask before adopting unrelated global Anaconda.

If absent, invoke `windows-tools-install-manager` for `<ToolsRoot>\miniconda`. If unavailable, stop and link `https://github.com/zzy256/windows-tools-install-manager`; do not improvise a download. Codex fallback:

```powershell
codex.cmd plugin marketplace add zzy256/windows-tools-install-manager --ref v1.1.0
codex.cmd plugin add windows-tools-install-manager@windows-tools-install-manager
```

Start a new task after installation, then retry Miniconda detection.

For a Miniconda install, require all of the following before execution:

- official HTTPS source and an explicitly identified/pinned release;
- SHA-256 verification against an independently published expected hash;
- Authenticode validation when the publisher supplies a signed installer;
- a displayed install path, flags, verification plan, and explicit confirmation.

If any source/version/path/channel/mode changes after failure, present the changed plan and reconfirm. Never silently fall back. Then verify by full path:

```powershell
$CondaExe = Join-Path $ToolsRoot 'miniconda\Scripts\conda.exe'
Invoke-NativeChecked { & $CondaExe --version } 'Miniconda verification'
```

Never accept terms for the user merely to create, inspect, export, or remove an environment.

## 4. Plan a new environment

Only reach this section when no reusable environment exists.

1. Choose `<task>-<YYYYMMDD-HHmmss>-<six-random-hex>` under `$TempEnvRoot` for
   TEMP, `Get-StableStandaloneEnvironmentPath -TempEnvRoot $TempEnvRoot
   -ScriptPath $ScriptPath` for STANDALONE, or `<project>\.conda` for PROJECT.
2. If `$TempEnvRoot` is missing, ask before creating that one directory.
3. For a PROJECT manifest, obtain the current solve preview below; show its sources,
   package count, and fingerprints. Then present origin, lifecycle/reason, absolute
   path, Python default, dependencies, retention, and preview; wait for confirmation.
4. Immediately before creation, acquire the canonical-prefix mutex, repeat the exact-path
   reuse/existence check under that lock, and stop if it appeared concurrently.
5. Create a sibling ownership claim with `FileMode.CreateNew` before invoking conda. A leftover
   claim is unresolved transaction state, never permission to delete a prefix.
6. Set `$CreationAttempted = $true` immediately before invoking conda, but set
   `$CreatedThisInvocation = $true` only after `python.exe` exists and passes a checked health run.

For a branch without a manifest, define an exact major/minor before displaying
the plan. Use the user's explicit version or a compatible project constraint;
otherwise use the documented default. Never allow a blank `python=` argument:

```powershell
$ManagedRoot = if ($Lifecycle -eq 'PROJECT') { $ProjectRoot } else { $TempEnvRoot }
Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
    -ManagedRoot $ManagedRoot -EnvPath $EnvPath
$condaPackageVariable = Get-Variable CondaPackages -ErrorAction SilentlyContinue
$pipPackageVariable = Get-Variable PipPackages -ErrorAction SilentlyContinue
$CondaPackages = if ($condaPackageVariable) { @($condaPackageVariable.Value) } else { @() }
$PipPackages = if ($pipPackageVariable) { @($pipPackageVariable.Value) } else { @() }
$selectedPython = Get-Variable PythonVersion -ErrorAction SilentlyContinue
$PythonVersion = if ($selectedPython -and
    -not [string]::IsNullOrWhiteSpace([string]$selectedPython.Value)) {
    [string]$selectedPython.Value
} else { '3.12' }
if ($PythonVersion -cnotmatch '^3\.[0-9]{1,2}$') {
    throw "Python version must be an exact supported major.minor: $PythonVersion"
}
$NoManifestApproval = New-CondaEnvironmentCreationApproval -Lifecycle $Lifecycle `
    -ManagedRoot $ManagedRoot -EnvPath $EnvPath -CondaExe $CondaExe `
    -PythonVersion $PythonVersion -ChannelPolicy isolated-conda-forge `
    -CondaPackages $CondaPackages -PipPackages $PipPackages
$NoManifestApproval | ConvertTo-Json -Depth 10
```

Show that JSON and wait for confirmation. Preserve or reconstruct that exact
record in later turns; changing lifecycle, path, conda executable, Python,
channel policy, or either package list requires a new plan and confirmation.

For STANDALONE, planning may precede script creation, but its parent must already
exist. Create and health-check the script before writing durable identity.

The path guard above runs before confirmation; the creation transaction repeats
it under the prefix lock immediately before conda. It enforces an exact direct
child and rejects junctions/symlinks for all three lifecycles.

Before entering Section 6's single outer boundary, initialize state only. Except
for the approved non-creating PROJECT dry-run below, do not acquire the mutex, mutate
`.gitignore`, reserve the prefix, or invoke conda outside that `try/finally`.
TEMP holds the lock and claim through task cleanup;
PROJECT/STANDALONE hold them through creation, Python health, and initial dependency bootstrap:

```powershell
$PrefixLock = $null
$CreationClaim = $null
$GitIgnoreTransaction = $null
$ManagedRoot = if ($Lifecycle -eq 'PROJECT') { $ProjectRoot } else { $TempEnvRoot }
$EnvName = Split-Path -Leaf (ConvertTo-CanonicalWindowsPath $EnvPath)
if ([string]::IsNullOrWhiteSpace($EnvName)) { throw "Environment path has no leaf: $EnvPath" }
$CreationAttempted = $false
$CreatedThisInvocation = $false
$ProjectPreview = $null
$PythonTaskCommand = $null # Set a checked task-specific scriptblock before creation.
$PrimaryError = $null; $CleanupErrors = New-Object System.Collections.Generic.List[object]
```

For PROJECT inside a Git worktree, keep `.conda` out of version control
**before** creation. A non-Git project needs no `.gitignore` mutation:

```powershell
$GitIgnoreTransaction = Protect-ProjectCondaGitIgnore `
    -ProjectRoot $ProjectRoot -EnvPath $EnvPath
```

The helper derives the Git root, rejects a tracked `.conda`, escapes literal
patterns, and updates UTF-8 `.gitignore` bytes through a reversible atomic
transaction. Run it only inside the outer boundary below.

Section 6 contains the only creation branches. For a PROJECT manifest, read
[PROJECT previews and safe conda manifests](references/project-manifests.md) in
full before preview, confirmation, creation, or export. Never create unless the
second `Assert-ManagedEnvironmentCreationPath` call succeeded under `$PrefixLock`.

## 5. Install dependencies according to environment ownership

### Newly created skill-owned conda env

Classify requested packages first; one unavailable item makes a conda batch
install nothing. After probing, rerun conda for the confirmed subset and use pip
only for the remainder:

```powershell
if ($ChannelPolicy -like 'project-*' -and ($CondaPackages -or $PipPackages)) {
    throw 'The approved PROJECT preview binds no post-create package list. Revise/re-preview conda dependencies, or finish creation and obtain a separate explicit approval before any pip bootstrap.'
}
if ($ChannelPolicy -notlike 'project-*') {
    if (-not $LockedCreationPlan) {
        throw 'Dependency bootstrap requires the locked no-manifest approval record.'
    }
    if (@($LockedCreationPlan.CondaPackages).Count) {
        $null = Invoke-CondaEnvironmentPackageInstall `
            -ApprovedPlan $LockedCreationPlan -Claim $CreationClaim
    }
    if (@($LockedCreationPlan.PipPackages).Count) {
        $null = Invoke-PipEnvironmentPackageInstall `
            -ApprovedPlan $LockedCreationPlan -Claim $CreationClaim
    }
}
```

Run checked import/CLI/version probes for every requested dependency afterward.

### Reused conda/Anaconda env

Preserve its configured channel priority and project policy. Use the child-scoped
helper with plain `install --prefix $EnvPath $Packages -y` (so CI/ToS auto-accept
is scrubbed), an existing environment file, or the project's documented command. Do **not** inject `conda-forge` or
`--override-channels` unless the user/project explicitly chose that migration.

### Reused `.venv`/`venv`

```powershell
Invoke-NativeChecked { & $PythonExe -m pip install $Packages } 'venv pip install'
```

Never issue `conda install`, `conda remove`, or `conda env export` for a venv.
For Poetry/uv/Pipenv/PDM, use the manager rather than direct pip where possible.

Python libraries/console packages belong in the selected env. End-user apps, Miniconda, and system CLIs belong to `windows-tools-install-manager`.
A console package needed by this project stays here; persistent user-global or
pipx-style CLI intent routes to `windows-tools-install-manager`.

## 6. Run with the selected interpreter and guarantee TEMP cleanup

Use direct interpreter paths, not activation. Before any creation, read
[Environment creation transaction](references/creation-transaction.md) in full
and execute its single outer `try/catch/finally` boundary. It binds the confirmed
plan under the prefix lock, reserves ownership before conda, protects PROJECT
`.gitignore`, writes durable STANDALONE identity only after script validation,
requires a task-specific checked command, and cleans only a TEMP prefix still
owned by this invocation. Never delete a reused/kept env or accept channel terms
to perform cleanup; preserve and report exact recovery state on failure.

## 7. Kept environments and safe manifests

For STANDALONE/PROJECT, report path, purpose, kind, direct-run, dependency, and restore commands.

Only conda envs use conda export; venvs/managers use their own workflow. Read
[PROJECT previews and safe conda manifests](references/project-manifests.md) in
full, then use `Invoke-CondaEnvironmentYamlExport`,
`Get-CondaEnvironmentManifestState`, and
`Write-CondaEnvironmentManifestAtomic`. Never hand-write, `Move-Item`, or blindly
overwrite `environment.yml`; the observed-state CAS writer owns staging,
equivalence, backup, atomic replacement, concurrent-change rejection, and cleanup.

## 8. Main-agent and subagent boundary

The main interactive agent owns environment selection/creation and user
confirmation. Before dispatching Python work, pass the exact interpreter:

> Use `D:\project\.conda\python.exe`; do not create or select another env. If it
> is missing or lacks a dependency, report back.

A subagent never creates or deletes an environment and never prompts the user.
It uses the supplied interpreter, otherwise detects an existing project env. If
none exists, it stops and reports the checked paths to the main agent.

## Stop conditions and common mistakes

Stop and reassess if any of these would happen:

- hard-coded config paths or a malformed config is ignored;
- a second env is created beside a usable `.conda`, `.venv`, or manager env;
- Python project code is written before the initial PROJECT env decision;
- a reused venv is passed to conda commands;
- a manager-owned `.venv` or `.conda` is treated as a generic environment;
- a reused conda/Anaconda env receives forced conda-forge channels;
- a project `.conda` is created before `.gitignore` protection;
- an existing `environment.yml` is overwritten without comparison/choice;
- a native command's `$LASTEXITCODE` is ignored;
- a TEMP cleanup is not in `finally`, or targets an env not created now;
- a changed Miniconda installation fallback proceeds without reconfirmation;
- a subagent creates an env while merely running tests.

## Changing configured roots

When asked to change roots, load `$observedConfigState` with the helper, validate
and display both old/new values, and get explicit confirmation. Then call
`Write-MinicondaRuntimeConfig` with that exact `-ExpectedState`; if another task
changed or removed the config while waiting, preserve its state and ask again.
Alternatively rerun fully parameterized `setup.ps1 -Force` from a verified
checkout. Do not hand-write the live JSON while an agent may be reading it.
