# miniconda-python-env

[![Release](https://img.shields.io/github/v/release/zzy256/miniconda-python-env?display_name=tag)](https://github.com/zzy256/miniconda-python-env/releases/latest)
[![Verify](https://github.com/zzy256/miniconda-python-env/actions/workflows/verify.yml/badge.svg)](https://github.com/zzy256/miniconda-python-env/actions/workflows/verify.yml)
[![License](https://img.shields.io/github/license/zzy256/miniconda-python-env)](LICENSE)

Predictable Python environments for Claude Code and Codex on Windows.

The skill reuses the environment that already owns a project before creating anything. When creation is required, it binds the exact interpreter, path, dependency policy, and lifecycle to an approved plan—then removes only temporary environments proven to belong to the current task.

> Current release: `v1.2.0` · Windows only · PowerShell 5.1+

## What belongs here?

| Request | Use this skill? | Result |
|---|---:|---|
| Run or develop a Python project | Yes | Reuse its existing manager/environment |
| Install project-scoped Python packages | Yes | Preserve the project's dependency policy |
| Run a reusable standalone Python script | Yes | Keep a stable script-owned environment |
| Perform one-off Python processing | Yes | Create and clean up a task-owned TEMP environment |
| Install Miniconda, a GUI app, or a global CLI | No | Use [`windows-tools-install-manager`](https://github.com/zzy256/windows-tools-install-manager) |
| Only report `python --version` or locate Python | No creation | Read-only inspection stays read-only |

Supported ownership signals include conda, venv, Poetry, uv, Pipenv, PDM, Pixi/Hatch/Rye, conda-lock, lock files, and manager-specific `pyproject.toml` tables.

## Install

Marketplace installation adds the skill but does not choose its runtime roots. The first real Python task asks once and stores validated paths.

### Codex

```powershell
codex.cmd plugin marketplace add zzy256/miniconda-python-env --ref v1.2.0
codex.cmd plugin add miniconda-python-env@miniconda-python-env
```

### Claude Code

```text
/plugin marketplace add https://github.com/zzy256/miniconda-python-env.git#v1.2.0
/plugin install miniconda-python-env@miniconda-python-env
```

Use `codex.cmd` on Windows to avoid an execution-policy failure in the npm-generated `codex.ps1` shim. Restart Claude Code or start a new Codex task after installation.

Marketplace refs pin the checkout but do not independently verify its signature. Use the flow below when a verified tag and transactional setup are required.

## AI INSTALLER QUICKSTART

When an AI agent receives this repository URL and is asked to install/configure the skill, it should use this transactional flow instead of copying individual files:

1. Ask for both runtime roots:
   - `TempEnvRoot`: TEMP and STANDALONE environments. Offer `D:\Projects\Claude\Temp` when `D:\` exists; otherwise `$env:LOCALAPPDATA\Claude\Temp`.
   - `ToolsRoot`: used only if Miniconda itself must be installed. Offer `D:\Tools` when `D:\` exists; otherwise `$env:USERPROFILE\Tools`.
2. Verify the signed annotated `v1.2.0` tag through GitHub, clone it to a new temporary directory, and compare local `HEAD` with the verified tag target.
3. Inspect the config plus selected Claude/Codex destinations and ask before replacing any of them.
4. Run `setup.ps1` with both roots and explicit agent selection. Add `-Force` only after replacement approval.
5. Require exit code `0`, parse the saved strict UTF-8 JSON, and verify the complete installed payload.
6. Delete only the temporary clone and tell the user to restart the agent.

<details>
<summary>Verified tag checkout</summary>

```powershell
$tagRef = Invoke-RestMethod `
    'https://api.github.com/repos/zzy256/miniconda-python-env/git/ref/tags/v1.2.0'
if ($tagRef.object.type -cne 'tag') { throw 'v1.2.0 is not an annotated tag.' }

$tagObject = Invoke-RestMethod $tagRef.object.url
if (-not $tagObject.verification.verified -or $tagObject.object.type -cne 'commit') {
    throw 'v1.2.0 is not a GitHub-verified signed tag that directly names a commit.'
}

$temporaryClone = Join-Path ([IO.Path]::GetTempPath()) `
    ('miniconda-python-env-' + [guid]::NewGuid().ToString('N'))
git clone --branch v1.2.0 --depth 1 `
    https://github.com/zzy256/miniconda-python-env.git $temporaryClone
if ($LASTEXITCODE -ne 0) { throw 'Pinned clone failed.' }

$head = (git -C $temporaryClone rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -cne [string]$tagObject.object.sha) {
    throw 'The checkout does not match the verified tag target.'
}
```

</details>

Install from the verified clone:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $temporaryClone\setup.ps1 `
    -TempEnvRoot $chosenTempEnvRoot -ToolsRoot $chosenToolsRoot `
    -Agent both -NonInteractive
```

Before using `-Force`, inspect:

- `%USERPROFILE%\.config\claude-skills\miniconda-python-env.json`
- `%USERPROFILE%\.claude\skills\miniconda-python-env`
- `%USERPROFILE%\.codex\skills\miniconda-python-env`

After setup, verify `SKILL.md`, `agents/openai.yaml`, and `scripts/EnvironmentHelpers.ps1` under each selected destination. Redirected or non-interactive input without every required parameter and overwrite approval fails before mutation.

## Configuration

The skill stores one shared strict UTF-8 JSON file:

```text
%USERPROFILE%\.config\claude-skills\miniconda-python-env.json
```

```json
{
  "temp_env_root": "D:\\Projects\\Claude\\Temp",
  "tools_root": "D:\\Tools"
}
```

Both values must be available, drive-qualified absolute Windows paths. Runtime reads and writes use a cross-process mutex, strict decoding, observed-state fingerprints, and same-directory atomic replacement. Invalid paths, reparse ancestors, incomplete transactions, or concurrent changes fail closed.

To change the roots, rerun setup explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 `
    -TempEnvRoot 'D:\PyTemp' -ToolsRoot 'D:\Tools' `
    -Agent both -Force -NonInteractive
```

## Environment decision model

The skill records trigger origin and lifecycle separately.

| Lifecycle | Typical signal | Default location | End state |
|---|---|---|---|
| `PROJECT` | Repository, manifest, lock file, or manager ownership | Existing env, otherwise `<project>\.conda` | Keep |
| `STANDALONE` | Reusable script outside a project | `<TempEnvRoot>\<script-slug>-<script-path-hash>` | Keep and reuse |
| `TEMP` | One-off work with no reusable output | `<TempEnvRoot>\<task>-<timestamp>-<random>` | Remove only if created now |

```text
Python task
  -> find nearest project without crossing a nearer Git boundary
  -> detect manager ownership and existing interpreter
  -> reuse when ownership is unambiguous
  -> otherwise classify PROJECT / STANDALONE / TEMP
  -> bind path + conda executable + Python + channels + packages
  -> show plan and wait for approval
  -> create, install, verify, run
  -> export kept conda env when approved
  -> clean TEMP only when claim + marker + path checks all match
```

A reused environment is never treated as transaction-owned and is never deleted. The main agent creates environments; subagents receive the exact interpreter path and reuse it.

## Dependency policy

| Situation | Policy |
|---|---|
| Existing Poetry/uv/Pipenv/PDM/Pixi/Hatch/Rye/conda-lock project | Use that manager's own workflow |
| Existing conda environment | Preserve its configured channel/project policy |
| Existing venv | Use its absolute `python.exe -m pip` |
| New env without a manifest | Pin approved Python, use isolated conda-forge first, use PyPI only when requested and unavailable there |
| New `environment.yml` project | Run a non-creating solve preview and approve exact manifest/config/solver fingerprints |

New no-manifest plans bind lifecycle, managed root, prefix, conda executable, Python major/minor, channel policy, and conda/pip package lists. Creation and bootstrap revalidate the locked record instead of consulting mutable planning variables.

Project manifests with pip mappings, activation variables, inline secrets, ambiguous sources, or non-HTTPS channels are rejected. Direct interpreter execution cannot safely reproduce activation-only variables, and pip dependencies require a separately reviewed requirements/lock file.

## Ownership and cleanup safety

- Creation requires an exact direct-child destination with no junction/symlink in the managed path.
- A sibling claim and in-prefix transaction marker prove current-invocation ownership.
- If conda replaces the reserved directory, the exact marker is restored before any cleanup decision.
- STANDALONE finalization replaces temporary ownership with durable canonical-script identity.
- TEMP cleanup requires the matching current claim, marker, leaf name, root, and non-reparse path.
- Conda-aware removal runs offline with an explicit conda-forge override; exact residual deletion occurs only after it succeeds.
- Unexpected or substituted state is preserved for inspection rather than recursively deleted.

## Conda isolation and exports

Creation and cleanup use a minimal child-only CONDARC so inherited defaults, pins, channels, `create_default_packages`, and `CONDA_*` variables cannot silently alter an approved solve. The temporary file is held against rename/delete, bound to its original Windows file identity and bytes, and removed only after the native child exits.

Kept conda environments can export `environment.yml` through a same-directory mutex/CAS writer. The export removes machine-specific `name`/`prefix`, audits sources, writes explicit approved channels plus `nodefaults` where applicable, and rejects credentials, variables, pip subsections, direct/editable URLs, and local paths. Pip packages need a separate reviewed lock file.

Miniconda installation itself belongs to the sister skill. Accessing Anaconda default channels may require terms acceptance; this skill never accepts terms for the user.

## Verify from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-codex-plugin.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\verify.ps1
```

The suite covers manifest/version consistency, exact snapshots, PowerShell 5.1 parsing, restricted-policy restoration, redirected input, transactional setup/config writes, manager routing, approval binding, held-CONDARC identity, real conda parsing when available, TEMP ownership and cleanup, export races, bounded native execution, and isolated plugin installation when the relevant CLI is available.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1+
- Claude Code and/or Codex
- Git and HTTPS access to GitHub for verified-tag installation
- Conda only when a conda environment must be used or created

## Sister skill

For system tools, end-user applications, global CLIs, and Miniconda itself, install [`windows-tools-install-manager`](https://github.com/zzy256/windows-tools-install-manager):

```powershell
codex.cmd plugin marketplace add zzy256/windows-tools-install-manager --ref v1.1.0
codex.cmd plugin add windows-tools-install-manager@windows-tools-install-manager
```

If that skill is unavailable when Miniconda must be installed, this skill stops rather than downloading an installer ad hoc.

## Signed release checklist

From a clean checkout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sync-codex-plugin.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\verify.ps1
$version = (Get-Content .\.codex-plugin\plugin.json -Raw -Encoding UTF8 |
    ConvertFrom-Json).version
git status --short
git tag -s "v$version" -m "miniconda-python-env v$version"
git push origin main
git push origin "v$version"
```

The release workflow accepts only a signed annotated tag whose version matches the manifests and changelog, reruns verification on Windows, then creates the GitHub Release.

## License

[MIT](LICENSE)
