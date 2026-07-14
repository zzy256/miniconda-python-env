# Changelog

All notable changes to `miniconda-python-env` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] — 2026-07-14

### Fixed

- Isolate no-manifest create/install and owned cleanup from inherited `.condarc`
  channels, default packages, pins, and `CONDA_*` overrides. Hold each minimal
  child-only CONDARC against mutation, bind it to the originally-created Windows
  file identity, and delete only that exact file after the native child exits.
- Parse held PROJECT manifests with conda's own `YamlFileSpec`, force the same
  built-in `environment.yml` specifier for preview and creation, and reject pip
  sections or activation variables that direct-interpreter execution cannot
  source-bind or apply.
- Revalidate the complete no-manifest approval record during conda and pip
  bootstrap, so ambient executable/path/version/package variables cannot drift.
  Keep dependency solves on the approved Python major/minor, reject duplicate
  `python` specs, recheck the interpreter, and reject pip subsections in export
  rather than generating a restore manifest that this skill itself refuses.
- Gate every setup, sync, config, `.gitignore`, manifest, and CONDARC fault hook
  behind an explicit test mode; detect dangling reparse points and transaction
  residue written by either the setup or runtime-config writer.
- Load the installed helper under a temporary process-only execution-policy
  bypass and restore the caller's original policy immediately, so the skill
  works under the default Windows `Restricted` policy without persistent policy
  changes or session-variable side effects.
- Accept one legacy leading UTF-8 BOM in runtime configuration while retaining
  strict UTF-8 decoding and fingerprinting the original bytes.
- Give STANDALONE scripts a cross-day canonical-path identity, retain separate
  durable ownership metadata after the creation claim is finalized, and reject
  missing, unfinished, wrong-script, or tampered identity state.
- Resolve the nearest Python project marker without crossing a nearer Git
  boundary, preserve drive roots during canonicalization, and recognize Pixi,
  Hatch, and Rye ownership instead of creating a parallel generic conda env.
- Define the no-manifest Python default and bind lifecycle, root, prefix, conda
  executable, Python version, channel policy, and validated package lists to a
  fingerprint rechecked under the prefix lock before creation.
- Restore the exact transaction marker when ordinary `conda create --prefix`
  replaces the reserved directory, using the same marker-protection wrapper as
  PROJECT creation before health checks, TEMP cleanup, or STANDALONE finalization.
- Replace prose-only `environment.yml` moves with a mutex-protected,
  same-directory CAS writer that normalizes line endings, performs atomic
  replacement, retains backups, rejects concurrent writes, and preserves all
  evidence if a second writer races restoration.
- Remove the Claude marketplace `strict: false` component override that made an
  apparently successful install fail to load because the marketplace and root
  plugin manifests conflicted.
- Read BOM-less UTF-8 configuration explicitly, validate both configured paths
  on every use, reject drive-relative/unsafe paths, and make redirected setup
  fail truthfully whenever a prompt or overwrite decision would be required.
- Replace setup destinations as whole directories and roll back config plus all
  previously committed targets when a later installation step fails.
- Keep trigger origin (`EXPLICIT`/`IMPLICIT`) independent from environment
  lifecycle (`TEMP`/`STANDALONE`/`PROJECT`). Reused venvs no longer flow into
  conda install/export commands; reused conda installs retain their existing
  channel policy, while PROJECT export is separately reclassified and audited.
- Restrict TEMP cleanup to a direct, newly-created child of `TempEnvRoot`, refuse
  reparse points, use conda-aware removal, and guarantee cleanup from `finally`.
- Give TEMP environments timestamp/random suffixes and recheck just before
  creation so concurrent or stale same-day directories are never mistaken for
  owned environments.
- Protect a new project `.conda` through `.gitignore` before creation and avoid
  blindly overwriting an existing `environment.yml`.
- Reject reserved Windows device names, invalid/ADS characters, trailing-dot or
  trailing-space components, and leading/trailing whitespace in managed roots.
- Protect setup and snapshot replacement with cross-process mutexes, fail closed
  on abandoned transaction residue, and restore canonical snapshots before
  attempting staging cleanup.
- Fail closed when transaction-residue directories cannot be enumerated, verify
  every rollback backup before deleting canonical state, and preserve the
  current usable copy if a backup has disappeared.
- Reject configured roots on unavailable drives and choose user-writable
  defaults when `D:\` is not mounted.
- Derive nested PROJECT `.gitignore` rules from the actual Git root, append
  safely when the file lacks a final newline, and refuse traversed reparse-point
  roots before TEMP creation or cleanup.
- Put dependency installation and task execution inside the same post-create
  `try/finally`, support `CONDA_EXE` from PowerShell conda initialization, and
  preserve channels when creating from an existing project manifest.
- Build the preferred conda candidate without provider resolution so a safe but
  currently unavailable drive does not make detection fail before fallback.
- Remove angle-bracket placeholders from frontmatter metadata so the official
  Codex skill validator accepts both source and snapshot copies.
- Prevent user `.condarc` channels (notably `defaults`) from leaking into an
  isolated conda-forge environment export. Reclassify PROJECT exports, require
  an approved preview for inherited policy, audit installed package sources,
  and reject config/channel drift before writing a restore manifest.
- Make isolated TEMP removal offline and channel-overridden; conda 26.1.1 can
  otherwise block local `remove --all` on unrelated unaccepted defaults ToS.
- Serialize first-use runtime-config writes with a per-path mutex, atomically
  replace same-directory JSON only when its observed fingerprint still matches,
  and preserve a concurrent writer's conflicting choice.
- Record rollback backup path types and stable byte/tree fingerprints in setup
  and snapshot sync; refuse canonical deletion when a backup is missing,
  substituted, or modified, while preserving current and staged recovery copies.
- Reject Windows' Unicode-superscript `COM`/`LPT` DOS-device aliases in
  addition to the ordinary digit forms.
- Apply one executable direct-child and reparse-point guard to TEMP,
  STANDALONE, and PROJECT creation, and repeat it immediately before conda can
  write the destination.
- Detect uv, Poetry, and PDM ownership from `pyproject.toml` even before a lock
  file exists, without treating duplicate same-manager signals as conflicts.
- Pass every required ownership argument in the documented TEMP `finally`
  cleanup call so the executable example cannot fall into parameter prompting.
- Bind PROJECT approval to the manifest, destination, isolation mode, channel
  configuration, resolved sources, variables, Python version, package count,
  and dry-run result; recheck the complete record immediately before creation.
- Use a dedicated absent solve prefix because conda 26 can remove an existing
  prefix even for `env create --dry-run`; restore the exact ownership marker if
  real `env create` removes it while replacing the approved destination.
- Parse both legacy `actions.LINK` and current conda 26 environment-plan JSON,
  require exactly one resolved Python version, and reject pip mappings that the
  conda dry-run cannot bind to an approved source.
- Hold the original PROJECT manifest read-only through each conda operation,
  reject reparse paths and inline URL secrets, scrub inherited CI/ToS acceptance
  variables in the child only, and use a minimal temporary `CONDARC` for safe
  public manifests.
- Export kept conda environments through `conda env export --no-builds`, remove
  wrapped machine-specific `name`/`prefix` YAML, reject variables, credentials,
  direct/editable URLs and local paths, and write approved channels plus
  `nodefaults` for every non-preserve policy.

### Changed

- Tighten trigger metadata so project pip/pytest work still routes here while
  read-only interpreter locate/version/status checks and persistent global or
  pipx-style end-user CLI installation do not.
- Require pinned official Miniconda sources, SHA-256 and applicable Authenticode
  verification, explicit confirmation, and reconfirmation before any fallback.
- Use checked `conda env export --no-builds` consistently so current and legacy
  conda installations follow one audited YAML path. Clarify that channel
  access—not Miniconda installation itself—may require user-owned Anaconda Terms
  acceptance.
- Mirror the complete Codex skill snapshot exactly, include all Mode 1 metadata,
  and document the Windows-safe `codex.cmd` command form.
- Make the AI installer use the transactional setup script from a pinned,
  verified release tag instead of directly copying mutable `main` resources.
- Use an explicit HTTPS Claude marketplace source and verify GitHub's signed tag
  object plus the cloned HEAD rather than depending on SSH or a local keyring.
- Trigger explicitly for runtime-root configuration requests and route later
  root changes through the observed-state atomic writer instead of live JSON edits.
- Pin repository text files to LF through `.gitattributes` to keep byte-exact
  source/snapshot comparisons stable across Windows Git configurations.
- Propagate a nonzero `gh release create` exit explicitly instead of relying on
  shell-wrapper behavior.
- Verify the GitHub-signed tag object and bind it to checkout `HEAD` before
  executing repository test scripts without persisted credentials; grant write
  permission only to a separate post-verification release job.
- Rewrite the GitHub README around lifecycle and dependency-policy tables, a
  marketplace-first quick start, and a compact ownership/cleanup decision flow.
- Build GitHub Release notes from the verified tag's matching changelog section
  and include pinned Codex and Claude Code installation commands.

### Added

- Add transactional setup, stale-file, rollback, UTF-8, description-budget,
  exact-snapshot, lifecycle-policy, and optional isolated Claude load tests.
- Add Windows verification/release workflows and a signed-tag release checklist.

## [1.1.2] — 2026-07-11

### Changed

- `tests/verify.ps1` now asserts the SKILL.md folded `description` stays within the 1024-byte Codex metadata limit.

## [1.1.1] — 2026-07-11

### Fixed

- Preserve drive-root paths such as `C:\` instead of converting them to drive-relative `C:` paths.
- Write exported `environment.yml` files explicitly as UTF-8 and remove machine-specific `prefix:` entries.

### Added

- Add Codex `agents/openai.yaml` interface metadata for plugin discovery and starter prompts.
- Install the complete skill directory so UI metadata is retained by `setup.ps1` installs.

## [1.1.0] — 2026-06-06

Lifecycle, reuse, and subagent fixes. Addresses two real-world failures on a
large PyQt project: (1) the skill never engaged while the project was being
built, so the project ended up on a non-conda Python; and (2) a dispatched
"run the tests" subagent then tried to create a fresh Miniconda env for what
should have been an ordinary test run, and had to be aborted by the main agent.

### Added

- **Step 2.5 "Detect an existing usable env — REUSE before you create."** Before any `conda create`, the skill now checks for an env it should reuse — an existing `<project>\.conda`, a `.venv`/`venv`, a lock-file toolchain, or the interpreter the session has already been using — and reuses it (skipping the creation + confirmation steps) instead of building a duplicate.
- **"Running inside a subagent / non-interactive task" section.** Establishes a division of labor: the main interactive session resolves/creates the env and passes the interpreter path into the subagent's prompt; a dispatched subagent **never** creates an env or asks for confirmation — it reuses the handed/detected env, or stops and reports back if none exists.
- **Scenario C lifecycle example** (Example 3): a PyQt app built task-by-task, env created once at project start and reused for every later run/test, including by test subagents.

### Changed

- **Description now covers Python *project development*, not just one-off run/install** — while preserving the A/B/C scenario model (it still states that env location & retention depend on task type: temp one-offs deleted vs in-project keepers at `<project>\.conda`). It triggers on developing a Python project across domains (ML/DL, data, web/API, crawler, automation, desktop/GUI) **whether the user names the stack** ("PyQt6 桌面工具", Django/Flask/FastAPI/PyTorch) **or states only a goal and the AI picks Python**, and instructs setting up the env FIRST then reusing it. Added an explicit "do NOT use for non-Python goals (JS/mobile/static sites)" guard so the broadened triggers don't over-fire. (Kept under the 1024-byte Codex limit: 1022 bytes.)
- **Disambiguated the Anaconda exclusion.** "Project uses Anaconda" was being read as "Anaconda is installed on the machine, so skip this skill entirely." The exclusion now only applies when the project is *configured* to use a conda/Anaconda env (existing env / lock / configured interpreter); if Anaconda is merely installed globally, ask first.
- **Broadened the "use their env" exclusion** to include bare `.venv`/`venv` directories, `requirements.txt`-only projects, and any interpreter the current work has already been using — not just lock files and activated venvs.
- **Core Rules** now lead with "reuse before you create" and "engage early for projects"; the plan/confirmation and cleanup rules clarify they apply to newly created envs, never to a reused one.
- Added matching Red Flags / Common Mistakes entries for duplicate-env creation, subagent-spawned envs, and deferring project env creation to test time.

## [1.0.5] — 2026-05-30

### Fixed

- Codex refused to load the skill with a "description exceeds 1024" error. The YAML `description` was 1062 characters but **1108 UTF-8 bytes** — over Codex's **1024-byte** limit (the many multi-byte Chinese trigger phrases pushed the byte total past the cap even though the character count was close). Rewrote the description to 586 characters / 596 bytes while preserving the same trigger and exclusion coverage, so the skill now loads in both Claude Code and Codex.

## [1.0.4] — 2026-05-19

### Changed

- Broadened the AI installer quickstart so any equivalent request to install, add, set up, enable, configure, or use the skill from the repository URL is treated as a Mode 1 AI install request.
- Added Chinese and English example phrasings for one-line AI installs, including `给我安装这个 skill`, `帮我装一下这个 Codex skill`, `install this skill`, `set up this Claude/Codex skill`, and `enable this skill from`.

## [1.0.3] — 2026-05-19

### Added

- Added a top-level **AI INSTALLER QUICKSTART** so users can give an AI the one-line request `请帮我安装这个 skill: https://github.com/zzy256/miniconda-python-env` and still get the full install + immediate path-configuration flow.
- Added verification coverage for the quickstart contract, including raw `SKILL.md` URL, Claude Code and Codex target paths, config JSON path, immediate user prompt, and the `setup.ps1` prohibition for AI tool-call installs.

## [1.0.2] — 2026-05-18

### Fixed

- Strengthened the `setup.ps1` non-interactive guard: redirected sessions now fail if either required path parameter is missing, preventing partial-parameter silent defaults.
- Replaced ambiguous lettered mode wording with the public Mode 1/2/3 terminology.
- Added a README fallback command for Windows PowerShell execution-policy blocks.
- Clarified Miniconda detection so global Anaconda is not silently treated as managed Miniconda.
- Documented full-path `conda.exe` use after chained Miniconda install, because PATH updates do not affect the current shell.
- Replaced the Scenario A cleanup snippet with a child-path validation guard before `Remove-Item`.
- Switched `setup.ps1` status output to ASCII to avoid mojibake in Windows PowerShell 5.

## [1.0.1] — 2026-05-18

Critical bug-fix release. v1.0.0 was unusable on Codex due to two issues:

### Fixed

- **SKILL.md YAML frontmatter `description` field now uses a folded block scalar (`>-`).** v1.0.0 had a long single-line `description:` value containing literal `:` characters (e.g., `HARD exclusion (overrides positive triggers above): do NOT use`). Strict YAML parsers (including Codex's) rejected this with `mapping values are not allowed in this context at line 2 column 519`. Claude Code's lenient parser tolerated it, which is why it slipped past pre-release testing. Folded block scalar treats the entire value as opaque text, so internal colons are safe.
- **Skill install directory for Codex corrected from `~/.agents/skills/` to `~/.codex/skills/`.** v1.0.0's README, Mode 1 prompt, and `setup.ps1` all pointed installs at the wrong path. Codex actually loads skills from `~/.codex/skills/`. All references updated.

### Notes

- If you installed v1.0.0 via Codex, your `~/.codex/skills/miniconda-python-env/SKILL.md` needs to be re-fetched from `main`. Easiest: paste the Mode 1 prompt again, or just overwrite the file from the latest raw URL.
- v1.0.0 Claude Code installs continue to work — Claude Code's parser tolerated the invalid YAML. But re-fetching the latest release is still recommended for cleanliness.

## [1.0.0] — 2026-05-12

Initial public release.

### Added

- Skill: **`miniconda-python-env`** — standardizes Python execution via Miniconda envs on Windows
- **Three install modes** for end users:
  - ⭐ Mode 1: AI-driven install (paste a prompt to an AI; recommended for non-technical users)
  - Mode 2: `/plugin install` from Claude Code marketplace
  - Mode 3: `git clone` + `setup.ps1` (power user / scripted install)
- **Self-configuring `SKILL.md`** via "Step 0 — Path Configuration":
  - Reads `~/.config/claude-skills/miniconda-python-env.json` silently on every invocation
  - On first run, asks the user once for two paths (TempEnvRoot + ToolsRoot)
  - Disambiguation warning that the paths are NOT where the skill itself lives
- **Three-scenario task classification (A / B / C)**:
  - A — Temp mid-task script: env auto-deleted after task
  - B — Standalone keeper script: env retained + `environment.yml` generated
  - C — Formal / long-lived project: env lives at `<project-root>\.conda\` + `environment.yml`
- **Conda-first dependency installs** with explicit `-c conda-forge --override-channels` for newly created skill-owned environments; pip only as fallback. Later releases clarified that Anaconda default-channel access can require user acceptance, while Miniconda installation itself does not.
- **Strict cleanup scope** for Scenario A: deletes ONLY this task's env folder; never widens to siblings or parents
- **`setup.ps1`** for pre-configuration: writes the config file + copies SKILL.md to agent skills dirs (Claude Code + Codex)
- Cross-agent support: `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json` with Codex `interface` metadata
- Cross-skill integration: chains into the sister skill `windows-tools-install-manager` if Miniconda is missing
- Strict NOT-USE clauses in the skill description for code reading, concept questions, technology comparisons, Python version lookups, projects with established non-conda toolchains, user-managed activated venvs, and env uninstall operations

### Notes

- Windows-only by design. macOS/Linux users would need to fork and adapt the PowerShell snippets.
- Sister skill: [windows-tools-install-manager](https://github.com/zzy256/windows-tools-install-manager) for installing Miniconda itself and other system tools.
