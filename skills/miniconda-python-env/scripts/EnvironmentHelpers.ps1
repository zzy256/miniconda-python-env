#Requires -Version 5.0

function Test-MinicondaPythonEnvFaultInjectionEnabled {
    return $env:MINICONDA_PYTHON_ENV_TEST_MODE -ceq '1'
}

function ConvertTo-Sha256Hex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) }
    finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash)).Replace('-', '')
}

function ConvertTo-CanonicalWindowsPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    return $full.TrimEnd('\')
}

function Get-FileByteState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $length = $stream.Length
        $hash = $sha.ComputeHash($stream)
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
    return [PSCustomObject]@{
        Length = [long]$length
        Fingerprint = ([BitConverter]::ToString($hash)).Replace('-', '')
    }
}

function Resolve-ConfiguredPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -cne $Value.Trim()) {
        throw "$Name cannot begin or end with whitespace."
    }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[A-Za-z]:[\\/]') {
        throw "$Name must be an absolute Windows path."
    }
    if ($Value -match '[;"%<>|?*]' -or $Value -match '[\x00-\x1f]' -or
        ($Value.Length -gt 2 -and $Value.Substring(2).Contains(':'))) {
        throw "$Name contains unsafe path characters."
    }
    $candidate = $Value.Replace('/', '\')
    foreach ($component in @($candidate.Substring(3) -split '\\' | Where-Object { $_ })) {
        if ($component -match '[. ]$') {
            throw "$Name contains a path component ending in a dot or space."
        }
        $deviceBase = (($component -split '\.', 2)[0]).TrimEnd(' ', '.')
        if ($deviceBase -match '^(?i:CON|PRN|AUX|NUL|COM(?:[1-9]|\u00B9|\u00B2|\u00B3)|LPT(?:[1-9]|\u00B9|\u00B2|\u00B3)|CONIN\$|CONOUT\$|CLOCK\$)$') {
            throw "$Name contains reserved Windows device component '$component'."
        }
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if (-not [IO.Directory]::Exists($driveRoot)) {
        throw "$Name is on a drive that is not currently available: $driveRoot"
    }
    if ($full -match '^[A-Za-z]:\\$') { return $full }
    return $full.TrimEnd('\')
}

function Resolve-SafeLiteralWindowsPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$RequireExisting,
        [switch]$RequireExistingParent,
        [ValidateSet('Any', 'File', 'Directory')][string]$ExistingType = 'Any'
    )

    $ExistingType = switch ($ExistingType.ToLowerInvariant()) {
        'file' { 'File' }
        'directory' { 'Directory' }
        default { 'Any' }
    }
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim() -or
        $Value -notmatch '^[A-Za-z]:[\\/]') {
        throw "$Name must be a fully qualified Windows path."
    }
    if ($Value -match '["<>|?*]' -or $Value -match '[\x00-\x1f]' -or
        ($Value.Length -gt 2 -and $Value.Substring(2).Contains(':'))) {
        throw "$Name contains characters Windows cannot address safely."
    }
    $candidate = $Value.Replace('/', '\')
    foreach ($component in @($candidate.Substring([Math]::Min(3, $candidate.Length)) -split '\\' |
        Where-Object { $_ })) {
        if ($component -in @('.', '..')) { continue }
        if ($component -match '[. ]$') {
            throw "$Name contains a path component ending in a dot or space: '$component'."
        }
        $deviceBase = (($component -split '\.', 2)[0]).TrimEnd(' ', '.')
        if ($deviceBase -match '^(?i:CON|PRN|AUX|NUL|COM(?:[1-9]|\u00B9|\u00B2|\u00B3)|LPT(?:[1-9]|\u00B9|\u00B2|\u00B3)|CONIN\$|CONOUT\$|CLOCK\$)$') {
            throw "$Name contains reserved Windows device component '$component'."
        }
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if (-not [IO.Directory]::Exists($driveRoot)) {
        throw "$Name is on a drive that is not currently available: $driveRoot"
    }
    if ($full -notmatch '^[A-Za-z]:\\$') { $full = $full.TrimEnd('\') }
    # This also detects dangling junction/symlink namespace entries for which
    # Test-Path returns false.
    Assert-NoReparseInExistingPath $full $Name
    $exists = Test-Path -LiteralPath $full
    if ($RequireExisting -and -not $exists) { throw "$Name does not exist: $full" }
    if ($RequireExistingParent) {
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "$Name parent directory does not exist: $parent"
        }
        Assert-NoReparseInExistingPath $parent "$Name parent"
    }
    if ($exists) {
        if ($ExistingType -ceq 'File' -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "$Name is not a regular file: $full"
        }
        if ($ExistingType -ceq 'Directory' -and -not (Test-Path -LiteralPath $full -PathType Container)) {
            throw "$Name is not a directory: $full"
        }
    }
    return $full
}

function Assert-NoReparseInExistingPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        $item = Get-LiteralWindowsNamespaceEntry -Path $cursor
        if ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Name traverses reparse point '$cursor'."
            }
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-LiteralWindowsNamespaceEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    try { return Get-Item -LiteralPath $full -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] {}
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf)) {
        return $null
    }
    try {
        $matches = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
            Where-Object { $_.Name.Equals($leaf, [StringComparison]::OrdinalIgnoreCase) })
    }
    catch [Management.Automation.ItemNotFoundException] { return $null }
    if ($matches.Count -gt 1) { throw "Ambiguous namespace entries differ only by case: $full" }
    return ($matches | Select-Object -First 1)
}

function Assert-ManagedEnvironmentCreationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('TEMP', 'STANDALONE', 'PROJECT')]
        [string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $Lifecycle = $Lifecycle.ToUpperInvariant()
    if ($Lifecycle -eq 'PROJECT') {
        if ([string]::IsNullOrWhiteSpace($ManagedRoot) -or $ManagedRoot -cne $ManagedRoot.Trim() -or
            $ManagedRoot -notmatch '^[A-Za-z]:[\\/]' -or
            -not (Test-Path -LiteralPath $ManagedRoot -PathType Container)) {
            throw 'PROJECT managed root must be an existing absolute Windows directory.'
        }
        if ([string]::IsNullOrWhiteSpace($EnvPath) -or $EnvPath -cne $EnvPath.Trim() -or
            $EnvPath -notmatch '^[A-Za-z]:[\\/]') {
            throw 'PROJECT environment path must be an absolute Windows path.'
        }
        $rootFull = [IO.Path]::GetFullPath($ManagedRoot.Replace('/', '\'))
        $envFull = [IO.Path]::GetFullPath($EnvPath.Replace('/', '\'))
    }
    else {
        $rootFull = Resolve-ConfiguredPath $ManagedRoot "$Lifecycle managed root"
        $envFull = Resolve-ConfiguredPath $EnvPath "$Lifecycle environment path"
    }
    if ($rootFull -notmatch '^[A-Za-z]:\\$') { $rootFull = $rootFull.TrimEnd('\') }
    if ($envFull -notmatch '^[A-Za-z]:\\$') { $envFull = $envFull.TrimEnd('\') }
    $envParent = [IO.Path]::GetFullPath((Split-Path -Parent $envFull))
    if ($envParent -notmatch '^[A-Za-z]:\\$') { $envParent = $envParent.TrimEnd('\') }
    if (-not $envParent.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Lifecycle environment must be a direct child of its managed root: $envFull"
    }
    if ($Lifecycle -eq 'PROJECT' -and (Split-Path -Leaf $envFull) -cne '.conda') {
        throw "PROJECT environment must be the exact .conda child of the project root: $envFull"
    }

    Assert-NoReparseInExistingPath $rootFull "$Lifecycle managed root"
    Assert-NoReparseInExistingPath $envFull "$Lifecycle environment path"
}

function Enter-ManagedEnvironmentMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30,
        [string]$MutexName
    )

    $canonical = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($MutexName)) {
        $lockId = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
        $MutexName = "Global\miniconda-python-env-prefix-$lockId"
    }
    $mutex = New-Object Threading.Mutex($false, $MutexName)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning "Recovered abandoned environment-prefix lock '$MutexName'; ownership claim and path state must be revalidated."
        }
        if (-not $acquired) {
            throw "Timed out waiting for environment-prefix lock '$MutexName': $EnvPath"
        }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $MutexName; EnvPath = $canonical }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-ManagedEnvironmentMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock)

    try {
        if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() }
    }
    finally { $Lock.Mutex.Dispose() }
}

function New-ManagedEnvironmentClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $Lifecycle = $Lifecycle.ToUpperInvariant()
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle -ManagedRoot $ManagedRoot -EnvPath $EnvPath
    $rootFull = [IO.Path]::GetFullPath($ManagedRoot)
    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    $leaf = Split-Path -Leaf $envFull
    $claimPath = Join-Path $rootFull (".$leaf.miniconda-python-env.claim")
    $markerLeaf = '.miniconda-python-env.owner.json'
    $markerPath = Join-Path $envFull $markerLeaf
    $stageDirectory = Join-Path $rootFull (".$leaf.miniconda-prefix-stage-$([guid]::NewGuid().ToString('N'))")
    Assert-NoReparseInExistingPath $claimPath "$Lifecycle ownership claim"
    $stagePattern = '^\.' + [regex]::Escape($leaf) + '\.miniconda-prefix-stage-[0-9a-f]{32}$'
    $stageResidue = @(Get-ChildItem -LiteralPath $rootFull -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $stagePattern })
    if ($stageResidue.Count -gt 0) {
        throw "Unresolved environment reservation stage requires manual recovery: $($stageResidue.FullName -join ' | ')"
    }
    if (Test-Path -LiteralPath $envFull) {
        throw "Environment path already exists; refusing to claim it: $envFull"
    }
    $ownerToken = [guid]::NewGuid().ToString('N')
    $payload = [ordered]@{
        lifecycle = $Lifecycle
        env_path = $envFull
        owner_token = $ownerToken
    } | ConvertTo-Json -Compress
    $bytes = (New-Object Text.UTF8Encoding($false, $true)).GetBytes($payload)
    $stream = $null
    $claimCreated = $false
    $stageCreated = $false
    $reservationCommitted = $false
    $stageFingerprint = $null
    try {
        New-Item -ItemType Directory -Path $stageDirectory -ErrorAction Stop | Out-Null
        $stageCreated = $true
        $stagedMarker = Join-Path $stageDirectory $markerLeaf
        $markerStream = [IO.File]::Open($stagedMarker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $markerStream.Write($bytes, 0, $bytes.Length)
            $markerStream.Flush($true)
        }
        finally { $markerStream.Dispose() }
        $stagedState = Get-StablePathState $stageDirectory
        if ($stagedState.Kind -cne 'Directory') { throw 'Environment reservation stage is not a directory.' }
        $stageFingerprint = $stagedState.Fingerprint
        $stream = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $claimCreated = $true
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.Directory]::Move($stageDirectory, $envFull)
        $stageCreated = $false
        $reservationCommitted = $true
    }
    catch {
        $originalError = $_
        if ($stream) { $stream.Dispose(); $stream = $null }
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        if ($claimCreated -and (Test-Path -LiteralPath $claimPath)) {
            try { Remove-Item -LiteralPath $claimPath -Force -ErrorAction Stop }
            catch { $cleanupErrors.Add("claim: $($_.Exception.Message)") }
        }
        if ($stageCreated -and (Test-Path -LiteralPath $stageDirectory)) {
            if ($stageFingerprint) {
                try {
                    $null = Assert-StablePathState $stageDirectory 'Directory' $stageFingerprint 'Environment reservation stage'
                    Remove-Item -LiteralPath $stageDirectory -Recurse -Force -ErrorAction Stop
                    $stageCreated = $false
                }
                catch { $cleanupErrors.Add("stage: $($_.Exception.Message)") }
            }
            else {
                $cleanupErrors.Add("stage: no stable ownership fingerprint was recorded for $stageDirectory")
            }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw "Environment reservation failed and left fail-closed recovery state. Original: $($originalError.Exception.Message) Cleanup: $($cleanupErrors -join ' | ')"
        }
        throw $originalError
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    if (-not $reservationCommitted) { throw 'Environment prefix reservation did not commit.' }
    return [PSCustomObject]@{
        Path = $claimPath
        Lifecycle = $Lifecycle
        EnvPath = $envFull
        OwnerToken = $ownerToken
        Fingerprint = ConvertTo-Sha256Hex $bytes
        MarkerPath = $markerPath
        MarkerFingerprint = ConvertTo-Sha256Hex $bytes
    }
}

function Assert-ManagedEnvironmentClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [switch]$AllowMissingMarkerIfEnvironmentExists
    )

    $Lifecycle = $Lifecycle.ToUpperInvariant()
    $expectedEnv = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    if (-not ([string]$Claim.Lifecycle).Equals($Lifecycle, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFullPath([string]$Claim.EnvPath).TrimEnd('\')).Equals($expectedEnv, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Environment ownership claim belongs to a different lifecycle or prefix.'
    }
    $claimPath = [IO.Path]::GetFullPath([string]$Claim.Path)
    $expectedClaimPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $expectedEnv) `
        (".$(Split-Path -Leaf $expectedEnv).miniconda-python-env.claim")))
    if (-not $claimPath.Equals($expectedClaimPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Environment ownership claim is not the exact sibling claim for the prefix: $claimPath"
    }
    Assert-NoReparseInExistingPath $claimPath "$Lifecycle ownership claim"
    if (-not (Test-Path -LiteralPath $claimPath -PathType Leaf)) {
        throw "Environment ownership claim is missing: $claimPath"
    }
    $state = Get-FileByteState $claimPath
    if ($state.Fingerprint -cne [string]$Claim.Fingerprint) {
        throw "Environment ownership claim changed; refusing destructive action: $claimPath"
    }
    $parsed = (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($claimPath)) | ConvertFrom-Json
    if (-not ([string]$parsed.lifecycle).Equals($Lifecycle, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$parsed.owner_token -cne [string]$Claim.OwnerToken -or
        -not ([IO.Path]::GetFullPath([string]$parsed.env_path).TrimEnd('\')).Equals($expectedEnv, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Environment ownership claim content does not match the requested prefix: $claimPath"
    }
    $environmentEntry = Get-LiteralWindowsNamespaceEntry -Path $expectedEnv
    if ($environmentEntry) {
        Assert-NoReparseInExistingPath $expectedEnv "$Lifecycle claimed environment"
        if (-not $environmentEntry.PSIsContainer) {
            throw "Claimed environment path is no longer a directory: $expectedEnv"
        }
        $markerPath = [IO.Path]::GetFullPath([string]$Claim.MarkerPath)
        $expectedMarkerPath = [IO.Path]::GetFullPath((Join-Path $expectedEnv '.miniconda-python-env.owner.json'))
        if (-not $markerPath.Equals($expectedMarkerPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Environment ownership marker is not inside the exact claimed prefix: $markerPath"
        }
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            if ($AllowMissingMarkerIfEnvironmentExists -and -not (Test-Path -LiteralPath $markerPath)) {
                return $claimPath
            }
            throw "Environment ownership marker is missing: $markerPath"
        }
        $markerState = Get-FileByteState $markerPath
        if ($markerState.Fingerprint -cne [string]$Claim.MarkerFingerprint -or
            $markerState.Fingerprint -cne [string]$Claim.Fingerprint) {
            throw "Environment ownership marker changed; refusing destructive action: $markerPath"
        }
        $markerParsed = (New-Object Text.UTF8Encoding($false, $true)).GetString(
            [IO.File]::ReadAllBytes($markerPath)) | ConvertFrom-Json
        if (-not ([string]$markerParsed.lifecycle).Equals($Lifecycle, [StringComparison]::OrdinalIgnoreCase) -or
            [string]$markerParsed.owner_token -cne [string]$Claim.OwnerToken -or
            -not ([IO.Path]::GetFullPath([string]$markerParsed.env_path).TrimEnd('\')).Equals(
                $expectedEnv, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Environment ownership marker content does not match the claimed prefix: $markerPath"
        }
    }
    return $claimPath
}

function Remove-ManagedEnvironmentClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $claimPath = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $EnvPath
    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    $markerBytes = $null
    $markerPath = $null
    if (Test-Path -LiteralPath $envFull) {
        $markerPath = [IO.Path]::GetFullPath([string]$Claim.MarkerPath)
        $markerBytes = [IO.File]::ReadAllBytes($markerPath)
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $markerPath) {
            throw "Environment ownership marker survived deletion: $markerPath"
        }
    }
    try { Remove-Item -LiteralPath $claimPath -Force -ErrorAction Stop }
    catch {
        $claimRemovalError = $_
        if (-not (Test-Path -LiteralPath $claimPath)) {
            # Remove-Item reported failure after the claim disappeared; the
            # marker is already gone, so the transaction is finalized.
            return
        }
        if ($markerBytes -and (Test-Path -LiteralPath $envFull -PathType Container) -and
            -not (Test-Path -LiteralPath $markerPath)) {
            try {
                $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle `
                    -EnvPath $envFull -AllowMissingMarkerIfEnvironmentExists
                $restoreStream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $restoreStream.Write($markerBytes, 0, $markerBytes.Length)
                    $restoreStream.Flush($true)
                }
                finally { $restoreStream.Dispose() }
                $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
            }
            catch {
                throw "Claim finalization and marker rollback both failed. Original: $($claimRemovalError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $claimRemovalError
    }
}

function Resolve-StandaloneScriptPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [switch]$RequireExisting
    )

    return Resolve-SafeLiteralWindowsPath -Value $ScriptPath `
        -Name 'STANDALONE script path' -RequireExisting:$RequireExisting `
        -RequireExistingParent -ExistingType File
}

function Get-StableStandaloneEnvironmentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TempEnvRoot,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [switch]$RequireExistingScript
    )

    $rootFull = Resolve-ConfiguredPath $TempEnvRoot 'STANDALONE managed root'
    $scriptFull = Resolve-StandaloneScriptPath -ScriptPath $ScriptPath `
        -RequireExisting:$RequireExistingScript
    $scriptKey = $scriptFull.ToUpperInvariant()
    $identity = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($scriptKey))
    $slug = [IO.Path]::GetFileNameWithoutExtension($scriptFull).ToLowerInvariant()
    $slug = ($slug -replace '[^a-z0-9-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'standalone' }
    if ($slug.Length -gt 32) { $slug = $slug.Substring(0, 32).TrimEnd('-') }
    $envPath = Join-Path $rootFull ("$slug-$($identity.Substring(0, 12).ToLowerInvariant())")
    Assert-ManagedEnvironmentCreationPath -Lifecycle STANDALONE `
        -ManagedRoot $rootFull -EnvPath $envPath
    return [PSCustomObject]@{
        EnvPath = $envPath
        ScriptPath = $scriptFull
        ScriptIdentity = $identity
        IdentityPath = Join-Path $envPath '.miniconda-python-env.standalone.json'
    }
}

function Write-StandaloneEnvironmentIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][string]$TempEnvRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $expected = Get-StableStandaloneEnvironmentPath -TempEnvRoot $TempEnvRoot `
        -ScriptPath $ScriptPath -RequireExistingScript
    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    if (-not $envFull.Equals([string]$expected.EnvPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "STANDALONE prefix does not match its stable script identity: $envFull"
    }
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle STANDALONE `
        -EnvPath $envFull
    $identityPath = [string]$expected.IdentityPath
    Assert-NoReparseInExistingPath $identityPath 'STANDALONE durable identity'
    $payload = [ordered]@{
        schema = 1
        lifecycle = 'STANDALONE'
        env_path = $envFull
        script_path = [string]$expected.ScriptPath
        script_identity = [string]$expected.ScriptIdentity
    } | ConvertTo-Json -Compress
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $bytes = $utf8.GetBytes($payload)
    $fingerprint = ConvertTo-Sha256Hex $bytes
    if (Test-Path -LiteralPath $identityPath) {
        if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
            throw "STANDALONE durable identity is not a regular file: $identityPath"
        }
        $state = Get-FileByteState $identityPath
        if ($state.Fingerprint -cne $fingerprint) {
            try {
                $saved = $utf8.GetString([IO.File]::ReadAllBytes($identityPath)) |
                    ConvertFrom-Json
            }
            catch {
                throw "STANDALONE durable identity already exists with invalid bytes: $identityPath | $($_.Exception.Message)"
            }
            if ([int]$saved.schema -ne 1 -or
                [string]$saved.lifecycle -cne 'STANDALONE' -or
                -not ([IO.Path]::GetFullPath([string]$saved.env_path).TrimEnd('\')).Equals(
                    $envFull, [StringComparison]::OrdinalIgnoreCase) -or
                -not ([IO.Path]::GetFullPath([string]$saved.script_path).TrimEnd('\')).Equals(
                    [string]$expected.ScriptPath, [StringComparison]::OrdinalIgnoreCase) -or
                [string]$saved.script_identity -cne [string]$expected.ScriptIdentity) {
                throw "STANDALONE durable identity already belongs to another script or prefix: $identityPath"
            }
            $fingerprint = $state.Fingerprint
        }
    }
    else {
        $stream = [IO.File]::Open($identityPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    $state = Get-FileByteState $identityPath
    if ($state.Fingerprint -cne $fingerprint) {
        throw "STANDALONE durable identity changed during finalization: $identityPath"
    }
    return [PSCustomObject]@{
        EnvPath = $envFull
        ScriptPath = [string]$expected.ScriptPath
        ScriptIdentity = [string]$expected.ScriptIdentity
        IdentityPath = $identityPath
        Fingerprint = $fingerprint
    }
}

function Get-OwnedStandaloneEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TempEnvRoot,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $expected = Get-StableStandaloneEnvironmentPath -TempEnvRoot $TempEnvRoot `
        -ScriptPath $ScriptPath -RequireExistingScript
    if (-not (Test-Path -LiteralPath $expected.EnvPath)) { return $null }
    if (-not (Test-Path -LiteralPath $expected.EnvPath -PathType Container)) {
        throw "Stable STANDALONE prefix is not a directory: $($expected.EnvPath)"
    }
    Assert-NoReparseInExistingPath $expected.EnvPath 'STANDALONE reusable prefix'
    $claimPath = Join-Path $TempEnvRoot `
        (".$(Split-Path -Leaf $expected.EnvPath).miniconda-python-env.claim")
    if (Test-Path -LiteralPath $claimPath) {
        throw "STANDALONE prefix has an unresolved creation claim: $claimPath"
    }
    if (-not (Test-Path -LiteralPath $expected.IdentityPath -PathType Leaf)) {
        throw "Existing STANDALONE prefix lacks durable script identity: $($expected.IdentityPath)"
    }
    Assert-NoReparseInExistingPath $expected.IdentityPath 'STANDALONE durable identity'
    $bytes = [IO.File]::ReadAllBytes($expected.IdentityPath)
    $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    try { $saved = $text | ConvertFrom-Json }
    catch { throw "STANDALONE durable identity is invalid JSON: $($_.Exception.Message)" }
    if ([int]$saved.schema -ne 1 -or [string]$saved.lifecycle -cne 'STANDALONE' -or
        -not ([IO.Path]::GetFullPath([string]$saved.env_path).TrimEnd('\')).Equals(
            [string]$expected.EnvPath, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFullPath([string]$saved.script_path).TrimEnd('\')).Equals(
            [string]$expected.ScriptPath, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$saved.script_identity -cne [string]$expected.ScriptIdentity) {
        throw "STANDALONE durable identity belongs to another script or prefix: $($expected.IdentityPath)"
    }
    return [PSCustomObject]@{
        EnvPath = [string]$expected.EnvPath
        ScriptPath = [string]$expected.ScriptPath
        ScriptIdentity = [string]$expected.ScriptIdentity
        IdentityPath = [string]$expected.IdentityPath
        Fingerprint = ConvertTo-Sha256Hex $bytes
    }
}

function Get-ManagedEnvironmentRecoveryClaim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $Lifecycle = $Lifecycle.ToUpperInvariant()
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $EnvPath
    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    $leaf = Split-Path -Leaf $envFull
    $claimPath = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($ManagedRoot)) `
        (".$leaf.miniconda-python-env.claim")))
    if (-not (Test-Path -LiteralPath $claimPath)) { return $null }
    Assert-NoReparseInExistingPath $claimPath "$Lifecycle recovery claim"
    if (-not (Test-Path -LiteralPath $claimPath -PathType Leaf)) {
        throw "Recovery claim path is not a regular file: $claimPath"
    }
    $bytes = [IO.File]::ReadAllBytes($claimPath)
    $fingerprint = ConvertTo-Sha256Hex $bytes
    $parsed = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) | ConvertFrom-Json
    if (-not ([string]$parsed.lifecycle).Equals($Lifecycle, [StringComparison]::OrdinalIgnoreCase) -or
        [string]$parsed.owner_token -cnotmatch '^[0-9a-f]{32}$' -or
        -not ([IO.Path]::GetFullPath([string]$parsed.env_path).TrimEnd('\')).Equals(
            $envFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Recovery claim content is invalid or belongs to another prefix: $claimPath"
    }
    $claim = [PSCustomObject]@{
        Path = $claimPath
        Lifecycle = $Lifecycle
        EnvPath = $envFull
        OwnerToken = [string]$parsed.owner_token
        Fingerprint = $fingerprint
        MarkerPath = Join-Path $envFull '.miniconda-python-env.owner.json'
        MarkerFingerprint = $fingerprint
    }
    $null = Assert-ManagedEnvironmentClaim -Claim $claim -Lifecycle $Lifecycle -EnvPath $envFull
    return $claim
}

function Remove-OwnedEnvironmentDirectoryKeepingMarkerLast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
    if (-not (Test-Path -LiteralPath $envFull)) { return }
    # Fingerprint the entire tree before deleting anything. Besides detecting
    # reparse points, this makes a sharing-violation fail while the ownership
    # marker is still intact, so cleanup can be retried safely.
    $null = Get-StablePathState $envFull
    $markerPath = [IO.Path]::GetFullPath([string]$Claim.MarkerPath)
    foreach ($child in @(Get-ChildItem -LiteralPath $envFull -Force -ErrorAction Stop)) {
        if ($child.FullName.Equals($markerPath, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Owned environment contains a reparse point; preserved marker and claim: $($child.FullName)"
        }
        Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
    }
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
    $remaining = @(Get-ChildItem -LiteralPath $envFull -Force -ErrorAction Stop)
    if ($remaining.Count -ne 1 -or
        -not $remaining[0].FullName.Equals($markerPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Owned environment cleanup did not reach marker-only state: $envFull"
    }
    $markerBytes = [IO.File]::ReadAllBytes($markerPath)
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop
    try {
        [IO.Directory]::Delete($envFull, $false)
    }
    catch {
        if ((Test-Path -LiteralPath $envFull -PathType Container) -and
            -not (Test-Path -LiteralPath $markerPath)) {
            try { [IO.File]::WriteAllBytes($markerPath, $markerBytes) } catch {}
        }
        throw
    }
    if (Test-Path -LiteralPath $envFull) {
        throw "Owned environment directory survived deletion; claim was preserved: $envFull"
    }
}

function Get-StablePathState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full)) {
        return [PSCustomObject]@{ Path = $full; Kind = 'Absent'; Fingerprint = $null }
    }

    $rootItem = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to fingerprint reparse point: $full"
    }

    if (-not $rootItem.PSIsContainer) {
        $fileState = Get-FileByteState $full
        return [PSCustomObject]@{
            Path = $full
            Kind = 'File'
            Fingerprint = $fileState.Fingerprint
        }
    }

    $rootPrefix = $full.TrimEnd('\') + '\'
    $records = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($full)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to fingerprint a tree containing reparse point: $($item.FullName)"
            }
            $relative = $item.FullName.Substring($rootPrefix.Length).Replace('\', '/')
            $relativeToken = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($relative))
            if ($item.PSIsContainer) {
                $records.Add("D|$relativeToken")
                $pending.Push($item.FullName)
            } else {
                $fileState = Get-FileByteState $item.FullName
                $records.Add("F|$relativeToken|$($fileState.Length)|$($fileState.Fingerprint)")
            }
        }
    }
    $ordered = @($records | Sort-Object)
    $payload = "DIRECTORY`n" + ($ordered -join "`n")
    return [PSCustomObject]@{
        Path = $full
        Kind = 'Directory'
        Fingerprint = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($payload))
    }
}

function Assert-StablePathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('File', 'Directory')][string]$ExpectedKind,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = Get-StablePathState $Path
    if ($actual.Kind -ne $ExpectedKind) {
        throw "$Label has type '$($actual.Kind)', expected '$ExpectedKind': $Path"
    }
    if ($actual.Fingerprint -cne $ExpectedFingerprint) {
        throw "$Label fingerprint changed; refusing to delete canonical state: $Path"
    }
    return $actual
}

function Enter-MinicondaConfigMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $canonical = [IO.Path]::GetFullPath($Path).TrimEnd('\').ToUpperInvariant()
    $lockId = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
    $name = if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_MUTEX_NAME) {
        $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_MUTEX_NAME
    } else {
        "Global\miniconda-python-env-config-$lockId"
    }
    $timeoutSeconds = 30
    $requestedTimeout = 0
    if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
        [int]::TryParse($env:MINICONDA_PYTHON_ENV_CONFIG_TEST_MUTEX_TIMEOUT_SECONDS, [ref]$requestedTimeout) -and
        $requestedTimeout -ge 1 -and $requestedTimeout -le 300) {
        $timeoutSeconds = $requestedTimeout
    }

    $mutex = New-Object Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($timeoutSeconds)) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning "Recovered abandoned runtime-config lock '$name'. State will be revalidated."
        }
        if (-not $acquired) {
            throw "Timed out waiting for another runtime-config writer (lock '$name')."
        }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MinicondaConfigMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock)

    try {
        if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() }
    }
    finally { $Lock.Mutex.Dispose() }
}

function Assert-NoMinicondaRuntimeConfigResidue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    $leaf = Split-Path -Leaf $full
    $runtimePattern = '^\.' + [regex]::Escape($leaf) + '\.(?:stage|replace-backup)-[0-9a-f]{32}$'
    $setupPattern = '^' + [regex]::Escape($leaf) + '\.(?:backup|staging)-[0-9a-f]{32}$'
    $residue = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $runtimePattern -or $_.Name -match $setupPattern })
    if ($residue.Count -gt 0) {
        throw "Unresolved runtime-config transaction residue requires manual recovery: $($residue.FullName -join ' | ')"
    }
}

function Get-MinicondaRuntimeConfigState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $lock = Enter-MinicondaConfigMutex $full
    try {
        Assert-NoMinicondaRuntimeConfigResidue $full
        $state = Get-StablePathState $full
        $content = $null
        if ($state.Kind -ceq 'File') {
            $bytes = [IO.File]::ReadAllBytes($full)
            if ((ConvertTo-Sha256Hex $bytes) -cne $state.Fingerprint) {
                throw "Runtime config changed while it was being read: $full"
            }
            # Decode strictly so malformed UTF-8 still fails closed.  Accept one
            # leading BOM written by Windows PowerShell 5.1-era setup versions;
            # the state fingerprint continues to describe the original bytes.
            $content = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
            if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
                $content = $content.Substring(1)
            }
        }
        return [PSCustomObject]@{
            Path = $state.Path
            Kind = $state.Kind
            Fingerprint = $state.Fingerprint
            Content = $content
        }
    }
    finally { Exit-MinicondaConfigMutex $lock }
}

function Write-MinicondaRuntimeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TempEnvRoot,
        [Parameter(Mandatory = $true)][string]$ToolsRoot,
        [Parameter(Mandatory = $true)]$ExpectedState
    )

    $full = [IO.Path]::GetFullPath($Path)
    if (-not ([IO.Path]::GetFullPath([string]$ExpectedState.Path)).Equals(
        $full, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Expected runtime-config state belongs to a different path.'
    }
    if ([string]$ExpectedState.Kind -notin @('Absent', 'File')) {
        throw "Refusing to replace runtime-config path type '$($ExpectedState.Kind)': $full"
    }
    if ([string]::IsNullOrWhiteSpace($TempEnvRoot) -or [string]::IsNullOrWhiteSpace($ToolsRoot)) {
        throw 'Runtime-config paths cannot be empty.'
    }

    $json = [ordered]@{
        temp_env_root = $TempEnvRoot
        tools_root = $ToolsRoot
    } | ConvertTo-Json -Compress
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $desiredBytes = $utf8.GetBytes($json)
    $desiredFingerprint = ConvertTo-Sha256Hex $desiredBytes
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    $stage = $null
    $replacementBackup = $null
    $lock = Enter-MinicondaConfigMutex $full
    try {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Assert-NoMinicondaRuntimeConfigResidue $full
        Assert-NoReparseInExistingPath $full 'Runtime config path under lock'

        $current = Get-StablePathState $full
        if ($current.Kind -ceq 'File' -and $current.Fingerprint -ceq $desiredFingerprint) {
            $currentBytes = [IO.File]::ReadAllBytes($full)
            if ((ConvertTo-Sha256Hex $currentBytes) -cne [string]$current.Fingerprint) {
                throw "Runtime config changed while it was being read: $full"
            }
            $saved = $utf8.GetString($currentBytes) | ConvertFrom-Json
            if ([string]$saved.temp_env_root -cne $TempEnvRoot -or [string]$saved.tools_root -cne $ToolsRoot) {
                throw 'Runtime-config bytes matched but parsed values did not.'
            }
            return [PSCustomObject]@{ Path = $full; Changed = $false; Fingerprint = $desiredFingerprint }
        }

        $expectedMatches = $current.Kind -ceq [string]$ExpectedState.Kind
        if ($expectedMatches -and $current.Kind -ceq 'File') {
            $expectedMatches = $current.Fingerprint -ceq [string]$ExpectedState.Fingerprint
        }
        if (-not $expectedMatches) {
            throw "Runtime config changed concurrently; preserved the current file: $full"
        }

        $stage = Join-Path $parent (".$leaf.stage-$([guid]::NewGuid().ToString('N'))")
        [IO.File]::WriteAllBytes($stage, $desiredBytes)
        $null = Assert-StablePathState $stage 'File' $desiredFingerprint 'Staged runtime config'
        $staged = $utf8.GetString([IO.File]::ReadAllBytes($stage)) | ConvertFrom-Json
        if ([string]$staged.temp_env_root -cne $TempEnvRoot -or [string]$staged.tools_root -cne $ToolsRoot) {
            throw 'Staged runtime config failed read-back validation.'
        }
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_FAIL_BEFORE_REPLACE -eq '1') {
            throw 'Simulated runtime-config failure before atomic replacement.'
        }

        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_BEFORE_REPLACE -eq '1') {
            [IO.File]::WriteAllText($full, '{"temp_env_root":"C:\\External","tools_root":"D:\\External"}', $utf8)
        }
        $null = Assert-MinicondaObservedPathState $full $current 'Runtime config'
        Assert-NoReparseInExistingPath $full 'Runtime config path before commit'

        if ($current.Kind -ceq 'Absent') {
            [IO.File]::Move($stage, $full)
        } else {
            $replacementBackup = Join-Path $parent (".$leaf.replace-backup-$([guid]::NewGuid().ToString('N'))")
            if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                $env:MINICONDA_PYTHON_ENV_CONFIG_TEST_EXTERNAL_WRITE_AT_REPLACE -eq '1') {
                [IO.File]::WriteAllText($full, '{"temp_env_root":"C:\\AtReplace","tools_root":"D:\\AtReplace"}', $utf8)
            }
            [IO.File]::Replace($stage, $full, $replacementBackup, $true)
            $displaced = Get-StablePathState $replacementBackup
            if ($displaced.Kind -cne 'File' -or $displaced.Fingerprint -cne $current.Fingerprint) {
                $committed = Get-StablePathState $full
                if ($displaced.Kind -ceq 'File' -and $committed.Kind -ceq 'File' -and
                    $committed.Fingerprint -ceq $desiredFingerprint) {
                    $ourCopy = Join-Path $parent (".$leaf.replace-backup-$([guid]::NewGuid().ToString('N'))")
                    [IO.File]::Replace($replacementBackup, $full, $ourCopy, $true)
                    $null = Assert-StablePathState $full 'File' $displaced.Fingerprint 'Restored concurrent runtime config'
                    $null = Assert-StablePathState $ourCopy 'File' $desiredFingerprint 'Displaced skill runtime config'
                    Remove-Item -LiteralPath $ourCopy -Force -ErrorAction Stop
                    $replacementBackup = $null
                    throw "Runtime config changed in the final replacement window; the external bytes were restored: $full"
                }
                throw "Runtime config changed in the final replacement window; preserved both copies: $full | $replacementBackup"
            }
        }
        $stage = $null
        $null = Assert-StablePathState $full 'File' $desiredFingerprint 'Saved runtime config'
        $saved = $utf8.GetString([IO.File]::ReadAllBytes($full)) | ConvertFrom-Json
        if ([string]$saved.temp_env_root -cne $TempEnvRoot -or [string]$saved.tools_root -cne $ToolsRoot) {
            throw 'Saved runtime config failed read-back validation.'
        }
        if ($replacementBackup) {
            Remove-Item -LiteralPath $replacementBackup -Force -ErrorAction Stop
            $replacementBackup = $null
        }
        return [PSCustomObject]@{ Path = $full; Changed = $true; Fingerprint = $desiredFingerprint }
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        Exit-MinicondaConfigMutex $lock
    }
}

function Enter-MinicondaGitIgnoreMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $canonical = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $lockId = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
    $name = "Global\miniconda-python-env-gitignore-$lockId"
    $mutex = New-Object Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning "Recovered abandoned .gitignore lock '$name'; file state will be revalidated."
        }
        if (-not $acquired) { throw "Timed out waiting for .gitignore lock '$name'." }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MinicondaGitIgnoreMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock)

    try { if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() } }
    finally { $Lock.Mutex.Dispose() }
}

function Assert-NoMinicondaGitIgnoreResidue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    $leaf = Split-Path -Leaf $full
    $pattern = '^\.' + [regex]::Escape($leaf) +
        '\.miniconda-(?:stage|replace-backup|rollback-stage|rollback-backup|rollback-delete)-[0-9a-f]{32}$'
    $residue = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $pattern })
    if ($residue.Count -gt 0) {
        throw "Unresolved .gitignore transaction residue requires manual recovery: $($residue.FullName -join ' | ')"
    }
}

function ConvertTo-GitIgnoreLiteralPattern {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath -match '[\x00\r\n]' -or
        [IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Git-ignore relative path must be non-empty, relative, and one line.'
    }
    $normalized = $RelativePath.Replace('\', '/').Trim('/')
    $segments = @($normalized -split '/')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw 'Git-ignore relative path contains an empty or traversal segment.'
    }
    $builder = New-Object Text.StringBuilder
    foreach ($character in $normalized.ToCharArray()) {
        if ($character -in @('\', '*', '?', '[', ']', '#', '!', ' ')) {
            [void]$builder.Append('\')
        }
        [void]$builder.Append($character)
    }
    return '/' + $builder.ToString() + '/'
}

function Assert-MinicondaObservedPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ExpectedState,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actual = Get-StablePathState $Path
    if ($actual.Kind -cne [string]$ExpectedState.Kind -or
        ($actual.Kind -ceq 'File' -and $actual.Fingerprint -cne [string]$ExpectedState.Fingerprint)) {
        throw "$Label changed concurrently; current bytes were preserved: $Path"
    }
    return $actual
}

function Add-GitIgnoreRuleAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Rule
    )

    $full = [IO.Path]::GetFullPath($Path)
    if ((Split-Path -Leaf $full) -cne '.gitignore') {
        throw "Atomic ignore writer only accepts an exact .gitignore path: $full"
    }
    if ($Rule -match '[\x00\r\n]' -or $Rule -notmatch '^/.+/$') {
        throw 'Git-ignore rule must be one anchored directory pattern.'
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Git worktree root does not exist: $parent"
    }
    Assert-NoReparseInExistingPath $parent 'Git worktree root'

    $lock = Enter-MinicondaGitIgnoreMutex $full
    $stage = $null
    $replaceBackup = $null
    try {
        Assert-NoMinicondaGitIgnoreResidue $full
        Assert-NoReparseInExistingPath $full '.gitignore path under lock'
        $before = Get-StablePathState $full
        if ($before.Kind -notin @('Absent', 'File')) {
            throw ".gitignore must be absent or a regular file, not '$($before.Kind)': $full"
        }
        $beforeBytes = if ($before.Kind -ceq 'File') { [IO.File]::ReadAllBytes($full) } else { [byte[]]@() }
        if ($before.Kind -ceq 'File' -and (ConvertTo-Sha256Hex $beforeBytes) -cne $before.Fingerprint) {
            throw ".gitignore changed while it was read: $full"
        }
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $beforeText = $strictUtf8.GetString($beforeBytes)
        $logicalText = if ($beforeText.Length -gt 0 -and $beforeText[0] -eq [char]0xFEFF) {
            $beforeText.Substring(1)
        } else { $beforeText }
        $newline = if ($logicalText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $separator = if ($logicalText.Length -eq 0 -or $logicalText.EndsWith("`n")) { '' } else { $newline }
        $appendBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($separator + $Rule + $newline)
        $desiredBytes = New-Object byte[] ($beforeBytes.Length + $appendBytes.Length)
        if ($beforeBytes.Length -gt 0) { [Array]::Copy($beforeBytes, 0, $desiredBytes, 0, $beforeBytes.Length) }
        [Array]::Copy($appendBytes, 0, $desiredBytes, $beforeBytes.Length, $appendBytes.Length)
        $desiredFingerprint = ConvertTo-Sha256Hex $desiredBytes

        $leaf = Split-Path -Leaf $full
        $stage = Join-Path $parent (".$leaf.miniconda-stage-$([guid]::NewGuid().ToString('N'))")
        [IO.File]::WriteAllBytes($stage, $desiredBytes)
        $null = Assert-StablePathState $stage 'File' $desiredFingerprint 'Staged .gitignore'

        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_BEFORE_REPLACE -eq '1') {
            [IO.File]::WriteAllText($full, 'external-before-replace', (New-Object Text.UTF8Encoding($false)))
        }
        $null = Assert-MinicondaObservedPathState $full $before '.gitignore'
        Assert-NoReparseInExistingPath $full '.gitignore path before commit'
        if ($before.Kind -ceq 'Absent') {
            [IO.File]::Move($stage, $full)
        }
        else {
            $replaceBackup = Join-Path $parent (".$leaf.miniconda-replace-backup-$([guid]::NewGuid().ToString('N'))")
            if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                $env:MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_REPLACE -eq '1') {
                [IO.File]::WriteAllText($full, 'external-at-replace', (New-Object Text.UTF8Encoding($false)))
            }
            [IO.File]::Replace($stage, $full, $replaceBackup, $true)
            $displaced = Get-StablePathState $replaceBackup
            if ($displaced.Kind -cne 'File' -or $displaced.Fingerprint -cne $before.Fingerprint) {
                $committed = Get-StablePathState $full
                if ($displaced.Kind -ceq 'File' -and $committed.Kind -ceq 'File' -and
                    $committed.Fingerprint -ceq $desiredFingerprint) {
                    $ourCopy = Join-Path $parent (".$leaf.miniconda-rollback-backup-$([guid]::NewGuid().ToString('N'))")
                    [IO.File]::Replace($replaceBackup, $full, $ourCopy, $true)
                    $null = Assert-StablePathState $full 'File' $displaced.Fingerprint 'Restored concurrent .gitignore'
                    $null = Assert-StablePathState $ourCopy 'File' $desiredFingerprint 'Displaced skill .gitignore'
                    Remove-Item -LiteralPath $ourCopy -Force -ErrorAction Stop
                    $replaceBackup = $null
                    throw ".gitignore changed in the final replacement window; the external bytes were restored: $full"
                }
                throw ".gitignore changed in the final replacement window; preserved both copies: $full | $replaceBackup"
            }
        }
        $stage = $null
        $null = Assert-StablePathState $full 'File' $desiredFingerprint 'Committed .gitignore'
        if ($replaceBackup) {
            Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction Stop
            $replaceBackup = $null
        }
        return [PSCustomObject]@{
            Path = $full
            Changed = $true
            Rule = $Rule
            BeforeKind = $before.Kind
            BeforeFingerprint = $before.Fingerprint
            BeforeBytesBase64 = [Convert]::ToBase64String($beforeBytes)
            AfterFingerprint = $desiredFingerprint
        }
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        Exit-MinicondaGitIgnoreMutex $lock
    }
}

function Undo-GitIgnoreRuleAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Transaction)

    if (-not $Transaction.Changed) { return }
    $full = [IO.Path]::GetFullPath([string]$Transaction.Path)
    if ((Split-Path -Leaf $full) -cne '.gitignore') { throw 'Invalid .gitignore rollback path.' }
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    $lock = Enter-MinicondaGitIgnoreMutex $full
    $stage = $null
    $backup = $null
    try {
        Assert-NoMinicondaGitIgnoreResidue $full
        Assert-NoReparseInExistingPath $full '.gitignore rollback path under lock'
        $current = Get-StablePathState $full
        if ($current.Kind -cne 'File' -or $current.Fingerprint -cne [string]$Transaction.AfterFingerprint) {
            throw ".gitignore changed after this invocation updated it; refusing rollback: $full"
        }
        if ([string]$Transaction.BeforeKind -ceq 'Absent') {
            $backup = Join-Path $parent (".$leaf.miniconda-rollback-delete-$([guid]::NewGuid().ToString('N'))")
            [IO.File]::Move($full, $backup)
            $moved = Get-StablePathState $backup
            if ($moved.Kind -cne 'File' -or $moved.Fingerprint -cne [string]$Transaction.AfterFingerprint) {
                if (-not (Test-Path -LiteralPath $full)) { [IO.File]::Move($backup, $full); $backup = $null }
                throw '.gitignore changed in the final rollback window; it was not deleted.'
            }
            Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
            $backup = $null
            return
        }
        if ([string]$Transaction.BeforeKind -cne 'File') {
            throw "Invalid .gitignore rollback source kind: $($Transaction.BeforeKind)"
        }
        $originalBytes = [Convert]::FromBase64String([string]$Transaction.BeforeBytesBase64)
        $originalFingerprint = ConvertTo-Sha256Hex $originalBytes
        if ($originalFingerprint -cne [string]$Transaction.BeforeFingerprint) {
            throw 'In-memory .gitignore rollback bytes no longer match their fingerprint.'
        }
        $stage = Join-Path $parent (".$leaf.miniconda-rollback-stage-$([guid]::NewGuid().ToString('N'))")
        [IO.File]::WriteAllBytes($stage, $originalBytes)
        $null = Assert-StablePathState $stage 'File' $originalFingerprint 'Staged .gitignore rollback'
        $null = Assert-StablePathState $full 'File' ([string]$Transaction.AfterFingerprint) 'Current .gitignore rollback target'
        $backup = Join-Path $parent (".$leaf.miniconda-rollback-backup-$([guid]::NewGuid().ToString('N'))")
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_GITIGNORE_TEST_WRITE_AT_ROLLBACK_REPLACE -eq '1') {
            [IO.File]::WriteAllText($full, 'external-at-rollback', (New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::Replace($stage, $full, $backup, $true)
        $stage = $null
        $displaced = Get-StablePathState $backup
        if ($displaced.Kind -cne 'File' -or
            $displaced.Fingerprint -cne [string]$Transaction.AfterFingerprint) {
            $restored = Get-StablePathState $full
            if ($displaced.Kind -ceq 'File' -and $restored.Kind -ceq 'File' -and
                $restored.Fingerprint -ceq $originalFingerprint) {
                $ourCopy = Join-Path $parent (".$leaf.miniconda-rollback-backup-$([guid]::NewGuid().ToString('N'))")
                [IO.File]::Replace($backup, $full, $ourCopy, $true)
                $null = Assert-StablePathState $full 'File' $displaced.Fingerprint 'Restored concurrent .gitignore rollback writer'
                $null = Assert-StablePathState $ourCopy 'File' $originalFingerprint 'Displaced skill .gitignore rollback'
                Remove-Item -LiteralPath $ourCopy -Force -ErrorAction Stop
                $backup = $null
                throw '.gitignore changed in the final rollback window; the external bytes were restored.'
            }
            throw ".gitignore changed in the final rollback window; preserved both copies: $full | $backup"
        }
        $null = Assert-StablePathState $full 'File' $originalFingerprint 'Restored .gitignore'
        Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
        $backup = $null
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        Exit-MinicondaGitIgnoreMutex $lock
    }
}

function Protect-ProjectCondaGitIgnore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath
    )

    $transaction = $null
    try {
        $gitProbe = Invoke-NativeCaptured {
            & git -C $ProjectRoot rev-parse --show-toplevel
        } 'git worktree detection'
        if ($gitProbe.ExitCode -ne 0) {
            if (($gitProbe.StdOut + "`n" + $gitProbe.StdErr) -match 'not a git repository') {
                return $null
            }
            throw "git worktree detection failed with exit code $($gitProbe.ExitCode).`n$($gitProbe.StdErr)"
        }

        $gitRoot = (($gitProbe.StdOut -split '\r?\n') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1).Trim()
        $gitRootFull = [IO.Path]::GetFullPath($gitRoot).TrimEnd('\') + '\'
        $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\') + '\'
        if (-not $envFull.StartsWith($gitRootFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'PROJECT env is outside the detected Git worktree.'
        }
        $envRelative = $envFull.Substring($gitRootFull.Length).TrimEnd('\').Replace('\', '/')
        $tracked = Invoke-NativeChecked {
            & git -C $gitRoot ls-files -- $envRelative "$envRelative/**"
        } 'git ls-files'
        if (-not [string]::IsNullOrWhiteSpace($tracked)) {
            throw "$envRelative is tracked; resolve repository state before creating an env there."
        }

        $gitignore = Join-Path $gitRoot '.gitignore'
        $probeRelative = "$envRelative/__skill_probe__"
        $ignoreProbe = Invoke-NativeCaptured {
            & git -C $gitRoot check-ignore --quiet -- $probeRelative
        } 'git check-ignore'
        if ($ignoreProbe.ExitCode -eq 1) {
            $rule = ConvertTo-GitIgnoreLiteralPattern -RelativePath $envRelative
            $transaction = Add-GitIgnoreRuleAtomic -Path $gitignore -Rule $rule
        }
        elseif ($ignoreProbe.ExitCode -ne 0) {
            throw "git check-ignore failed with exit code $($ignoreProbe.ExitCode).`n$($ignoreProbe.StdErr)"
        }
        $ignoreVerify = Invoke-NativeCaptured {
            & git -C $gitRoot check-ignore --quiet -- $probeRelative
        } 'git check-ignore verification'
        if ($ignoreVerify.ExitCode -ne 0) {
            throw "$envRelative is not effectively ignored. git exit=$($ignoreVerify.ExitCode).`n$($ignoreVerify.StdErr)"
        }
        return $transaction
    }
    catch {
        $originalError = $_
        if ($transaction) {
            try { Undo-GitIgnoreRuleAtomic $transaction }
            catch {
                throw "PROJECT .gitignore setup failed and its atomic rollback also failed. Original: $($originalError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
        }
        throw $originalError
    }
}

function Resolve-PythonProjectRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StartPath)

    $startFull = Resolve-SafeLiteralWindowsPath -Value $StartPath `
        -Name 'Python project search path' -RequireExisting
    $item = Get-Item -LiteralPath $startFull -Force -ErrorAction Stop
    $cursor = if ($item.PSIsContainer) { $item.FullName } else { $item.Directory.FullName }
    $markers = @(
        'pyproject.toml', 'environment.yml', 'environment.yaml',
        'conda-lock.yml', 'conda-lock.yaml', 'uv.lock', 'poetry.lock',
        'Pipfile', 'Pipfile.lock', 'pdm.lock', 'pixi.toml', 'pixi.lock',
        'setup.py', 'setup.cfg', 'requirements.txt', '.python-version'
    )
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $hasMarker = $false
        foreach ($marker in $markers) {
            if (Test-Path -LiteralPath (Join-Path $cursor $marker) -PathType Leaf) {
                $hasMarker = $true
                break
            }
        }
        if ($hasMarker) { return ConvertTo-CanonicalWindowsPath $cursor }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) {
            return ConvertTo-CanonicalWindowsPath $cursor
        }
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $null
}

function Get-ProjectPythonManager {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $managers = @()
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'uv.lock') -PathType Leaf) {
        $managers += 'uv'
    }
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'poetry.lock') -PathType Leaf) {
        $managers += 'poetry'
    }
    if ((Test-Path -LiteralPath (Join-Path $ProjectRoot 'Pipfile.lock') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $ProjectRoot 'Pipfile') -PathType Leaf)) {
        $managers += 'pipenv'
    }
    if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'pdm.lock') -PathType Leaf) {
        $managers += 'pdm'
    }
    if ((Test-Path -LiteralPath (Join-Path $ProjectRoot 'pixi.lock') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $ProjectRoot 'pixi.toml') -PathType Leaf)) {
        $managers += 'pixi'
    }
    if ((Test-Path -LiteralPath (Join-Path $ProjectRoot 'conda-lock.yml') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $ProjectRoot 'conda-lock.yaml') -PathType Leaf)) {
        $managers += 'conda-lock'
    }
    $pyprojectPath = Join-Path $ProjectRoot 'pyproject.toml'
    if (Test-Path -LiteralPath $pyprojectPath -PathType Leaf) {
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $pyproject = [IO.File]::ReadAllText($pyprojectPath, $strictUtf8)
        if ($pyproject -match '(?m)^\s*\[tool\.uv(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'uv'
        }
        if ($pyproject -match '(?m)^\s*\[tool\.poetry(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'poetry'
        }
        if ($pyproject -match '(?m)^\s*\[tool\.pdm(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'pdm'
        }
        if ($pyproject -match '(?m)^\s*\[tool\.pixi(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'pixi'
        }
        if ($pyproject -match '(?m)^\s*\[tool\.hatch(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'hatch'
        }
        if ($pyproject -match '(?m)^\s*\[tool\.rye(?:\.[^\]]+)?\]\s*(?:#.*)?$') {
            $managers += 'rye'
        }
    }
    $managers = @($managers | Select-Object -Unique)
    if ($managers.Count -gt 1) {
        throw "Conflicting Python manager signals: $($managers -join ', ')"
    }
    return ($managers | Select-Object -First 1)
}

function Assert-SimpleCondaPackageSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Spec)

    if ($Spec -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*(?:(?:==|!=|<=|>=|~=|=|<|>)[A-Za-z0-9*+_.!,<>=-]+)?(?:=[A-Za-z0-9*+_.-]+)?$') {
        throw "Conda package must be a simple name/version/build spec without flags, channels, URLs, paths, or whitespace: $Spec"
    }
    return $Spec
}

function Assert-SimplePipPackageSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Spec)

    if ($Spec -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*(?:\[[A-Za-z0-9_,.-]+\])?(?:(?:===|==|!=|<=|>=|~=|<|>)[A-Za-z0-9*+_.!,<>=-]+)?$') {
        throw "Pip package must be a simple index name/version spec without flags, URLs, paths, markers, or whitespace: $Spec"
    }
    return $Spec
}

function New-CondaEnvironmentCreationApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)]
        [ValidateSet('isolated-conda-forge')][string]$ChannelPolicy,
        [AllowEmptyCollection()][string[]]$CondaPackages = @(),
        [AllowEmptyCollection()][string[]]$PipPackages = @()
    )

    $Lifecycle = $Lifecycle.ToUpperInvariant()
    $ChannelPolicy = $ChannelPolicy.ToLowerInvariant()
    if ($PythonVersion -cnotmatch '^3\.[0-9]{1,2}$') {
        throw "Python version must be an exact major.minor: $PythonVersion"
    }
    $validatedCondaPackages = @($CondaPackages | ForEach-Object {
        Assert-SimpleCondaPackageSpec ([string]$_)
    })
    if ($validatedCondaPackages | Where-Object {
            $_ -match '^(?i:python)(?:(?:==|!=|<=|>=|~=|=|<|>).*)?$'
        }) {
        throw 'Python is approved through PythonVersion; remove python from CondaPackages.'
    }
    $validatedPipPackages = @($PipPackages | ForEach-Object {
        Assert-SimplePipPackageSpec ([string]$_)
    })
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $EnvPath
    $condaFull = Resolve-SafeLiteralWindowsPath -Value $CondaExe `
        -Name 'Approved conda executable' -RequireExisting -ExistingType File
    $record = [ordered]@{
        Lifecycle = $Lifecycle
        ManagedRoot = ConvertTo-CanonicalWindowsPath $ManagedRoot
        EnvPath = ConvertTo-CanonicalWindowsPath $EnvPath
        CondaExe = $condaFull
        PythonVersion = $PythonVersion
        ChannelPolicy = $ChannelPolicy
        CondaPackages = $validatedCondaPackages
        PipPackages = $validatedPipPackages
    }
    $canonical = $record | ConvertTo-Json -Depth 10 -Compress
    $fingerprint = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
    return [PSCustomObject]@{
        Lifecycle = $record.Lifecycle
        ManagedRoot = $record.ManagedRoot
        EnvPath = $record.EnvPath
        CondaExe = $record.CondaExe
        PythonVersion = $record.PythonVersion
        ChannelPolicy = $record.ChannelPolicy
        CondaPackages = @($record.CondaPackages)
        PipPackages = @($record.PipPackages)
        ApprovalFingerprint = $fingerprint
    }
}

function Assert-CondaEnvironmentCreationApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ApprovedPlan,
        [Parameter(Mandatory = $true)]
        [ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)]
        [ValidateSet('isolated-conda-forge')][string]$ChannelPolicy,
        [AllowEmptyCollection()][string[]]$CondaPackages = @(),
        [AllowEmptyCollection()][string[]]$PipPackages = @()
    )

    $approvedIntegrity = New-CondaEnvironmentCreationApproval `
        -Lifecycle ([string]$ApprovedPlan.Lifecycle) `
        -ManagedRoot ([string]$ApprovedPlan.ManagedRoot) `
        -EnvPath ([string]$ApprovedPlan.EnvPath) `
        -CondaExe ([string]$ApprovedPlan.CondaExe) `
        -PythonVersion ([string]$ApprovedPlan.PythonVersion) `
        -ChannelPolicy ([string]$ApprovedPlan.ChannelPolicy) `
        -CondaPackages @($ApprovedPlan.CondaPackages) `
        -PipPackages @($ApprovedPlan.PipPackages)
    if ([string]$approvedIntegrity.ApprovalFingerprint -cne
        [string]$ApprovedPlan.ApprovalFingerprint) {
        throw 'Approved no-manifest creation record is incomplete or changed.'
    }
    $current = New-CondaEnvironmentCreationApproval -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $EnvPath -CondaExe $CondaExe `
        -PythonVersion $PythonVersion -ChannelPolicy $ChannelPolicy `
        -CondaPackages $CondaPackages -PipPackages $PipPackages
    if ([string]$current.ApprovalFingerprint -cne
        [string]$ApprovedPlan.ApprovalFingerprint) {
        throw 'No-manifest environment plan changed after confirmation; display and confirm again.'
    }
    return $current
}

function Get-LockedCondaEnvironmentCreationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ApprovedPlan)

    return Assert-CondaEnvironmentCreationApproval -ApprovedPlan $ApprovedPlan `
        -Lifecycle ([string]$ApprovedPlan.Lifecycle) `
        -ManagedRoot ([string]$ApprovedPlan.ManagedRoot) `
        -EnvPath ([string]$ApprovedPlan.EnvPath) `
        -CondaExe ([string]$ApprovedPlan.CondaExe) `
        -PythonVersion ([string]$ApprovedPlan.PythonVersion) `
        -ChannelPolicy ([string]$ApprovedPlan.ChannelPolicy) `
        -CondaPackages @($ApprovedPlan.CondaPackages) `
        -PipPackages @($ApprovedPlan.PipPackages)
}

function Invoke-NativeCaptured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $captureId = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) "mini-native-$captureId.stdout"
    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) "mini-native-$captureId.stderr"
    try {
        $previousPreference = $ErrorActionPreference
        try {
            # Windows PowerShell 5.1 turns native stderr into ErrorRecord objects.
            # Continue here so an exit-0 warning cannot terminate before the real
            # native exit code is captured. The two streams remain separate.
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = $null
            & $Command 1> $stdoutPath 2> $stderrPath
            $code = $global:LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($null -eq $code) { $code = -1 }
        $stdoutText = if (Test-Path -LiteralPath $stdoutPath) {
            Get-Content -LiteralPath $stdoutPath -Raw
        } else { '' }
        $stderrText = if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath -Raw
        } else { '' }
        return [PSCustomObject]@{
            ExitCode = [int]$code
            StdOut   = [string]$stdoutText
            StdErr   = [string]$stderrText
            Label    = $Label
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $result = Invoke-NativeCaptured -Command $Command -Label $Label
    if ($result.ExitCode -ne 0) {
        $details = @($result.StdOut, $result.StdErr) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        throw "$Label failed with exit code $($result.ExitCode).`n$($details -join "`n")"
    }
    if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
        Write-Warning "$Label wrote diagnostics to stderr; they were excluded from stdout.`n$($result.StdErr.Trim())"
    }
    return $result.StdOut
}

function Get-IsolatableProjectManifestChannels {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    $full = [IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Project environment manifest does not exist: $full"
    }
    $text = (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($full))
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $lines = @($text -split '\r?\n')
    $headers = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^channels\s*:\s*(?<tail>.*?)\s*$') {
            $headers += [PSCustomObject]@{ Index = $index; Tail = $Matches.tail }
        }
    }
    if ($headers.Count -ne 1) {
        throw 'Safe PROJECT channel isolation requires exactly one unindented channels: key.'
    }

    $channels = New-Object System.Collections.Generic.List[string]
    $tail = [string]$headers[0].Tail
    if (-not [string]::IsNullOrWhiteSpace($tail)) {
        if ($tail -notmatch '^\[(?<items>[^\]]*)\]\s*(?:#.*)?$') {
            throw 'Safe PROJECT channel isolation only accepts a simple inline channel list or block sequence.'
        }
        foreach ($item in @($Matches.items -split ',')) {
            $value = $item.Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\s\[\],#]') {
                throw "Unsupported inline PROJECT channel syntax: $item"
            }
            $channels.Add($value)
        }
    }
    else {
        for ($index = [int]$headers[0].Index + 1; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            if ($line -match '^\s*(?:#.*)?$') { continue }
            if ($line -match '^\S') { break }
            if ($line -notmatch '^\s+-\s*(?:"(?<double>[^"]+)"|''(?<single>[^'']+)''|(?<plain>[^\s#]+))\s*(?:#.*)?$') {
                throw "Unsupported PROJECT channels block syntax: $line"
            }
            $value = if ($Matches.double) { $Matches.double } elseif ($Matches.single) { $Matches.single } else { $Matches.plain }
            $channels.Add($value)
        }
    }
    if ($channels.Count -eq 0 -or -not ($channels -ccontains 'nodefaults')) {
        throw 'Safe PROJECT channel isolation requires an explicit nodefaults entry.'
    }
    $actualChannels = @($channels | Where-Object { $_ -cne 'nodefaults' })
    if ($actualChannels.Count -eq 0) {
        throw 'PROJECT manifest declares nodefaults but no usable channel.'
    }
    foreach ($channel in $actualChannels) {
        if ($channel -notmatch '^(?:conda-forge(?:/label/[A-Za-z0-9_.-]+)?|https://[^\s]+)$') {
            throw "PROJECT channel '$channel' depends on defaults, a short private name, or custom mapping; refusing to change its resolution."
        }
    }
    foreach ($qualified in [regex]::Matches($text, '(?<![A-Za-z0-9_.-])(?<channel>[A-Za-z0-9_.-]+)::')) {
        if ($qualified.Groups['channel'].Value -cne 'conda-forge') {
            throw "PROJECT dependency uses channel qualifier '$($qualified.Groups['channel'].Value)::'; refusing to remap it through public isolation."
        }
    }
    return @($channels)
}

function ConvertTo-WindowsNativeArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-ProcessCapturedChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList,
        [hashtable]$Environment = @{},
        [string]$RemoveEnvironmentNamePattern,
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $sourceEnvironment = [Environment]::GetEnvironmentVariables()
    $deduplicated = New-Object 'Collections.Generic.Dictionary[string,string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceName in @($sourceEnvironment.Keys)) {
        $name = [string]$sourceName
        $value = [string]$sourceEnvironment[$sourceName]
        if ($deduplicated.ContainsKey($name)) {
            if ([string]$deduplicated[$name] -cne $value) {
                throw "Process environment contains case-colliding variables with different values: $name"
            }
            continue
        }
        $deduplicated.Add($name, $value)
    }

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-WindowsNativeArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $workingFull = [IO.Path]::GetFullPath($WorkingDirectory)
        Assert-NoReparseInExistingPath $workingFull "$Label working directory"
        $psi.WorkingDirectory = $workingFull
    }
    # WinPS 5.1 may swallow a duplicate Path/PATH exception on the first lazy
    # getter and leave a partial dictionary. Warm it, then replace every entry
    # from our independently deduplicated process environment.
    try { $null = $psi.EnvironmentVariables } catch {}
    $childEnvironment = $psi.EnvironmentVariables
    if ($null -eq $childEnvironment) {
        try { $null = $psi.Environment } catch {}
        $childEnvironment = $psi.Environment
    }
    if ($null -eq $childEnvironment) { throw 'ProcessStartInfo exposed no writable child environment dictionary.' }
    $childEnvironment.Clear()
    foreach ($entry in $deduplicated.GetEnumerator()) {
        $childEnvironment[$entry.Key] = $entry.Value
    }
    if (-not [string]::IsNullOrWhiteSpace($RemoveEnvironmentNamePattern)) {
        foreach ($name in @($childEnvironment.Keys)) {
            if ([string]$name -match $RemoveEnvironmentNamePattern) {
                $null = $childEnvironment.Remove([string]$name)
            }
        }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $childEnvironment[[string]$entry.Key] = [string]$entry.Value
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Failed to start $Label." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0) {
            $details = @($stdout, $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            throw "$Label failed with exit code $($process.ExitCode).`n$($details -join "`n")"
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Warning "$Label wrote diagnostics to stderr; they were excluded from stdout.`n$($stderr.Trim())"
        }
        return $stdout
    }
    finally { $process.Dispose() }
}

function Get-OpenFileStreamSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    if (-not $Stream.CanRead) { throw 'The held file stream is not readable.' }
    $position = $Stream.Position
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $Stream.Position = $position
    }
}

function Initialize-MinicondaHeldFileApi {
    if ('MinicondaPythonEnv.NativeHeldFile' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace MinicondaPythonEnv {
    public static class NativeHeldFile {
        private const uint GENERIC_READ = 0x80000000;
        private const uint DELETE = 0x00010000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const int FileDispositionInfo = 4;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILE_DISPOSITION_INFO {
            public byte DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass,
            ref FILE_DISPOSITION_INFO info, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle,
            out BY_HANDLE_FILE_INFORMATION info);

        private static FileStream Open(string path, uint access, uint share, string operation) {
            SafeFileHandle handle = CreateFileW(path, access, share,
                IntPtr.Zero, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
            if (handle.IsInvalid) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, operation);
            }
            return new FileStream(handle, FileAccess.Read);
        }

        public static FileStream OpenReadHeld(string path) {
            // Do not request DELETE here: normal Python/Conda readers do not
            // share DELETE, so a READ|DELETE holder makes the CONDARC unreadable.
            return Open(path, GENERIC_READ, FILE_SHARE_READ,
                "Could not open held temporary file for reading");
        }

        public static FileStream OpenReadDeleteExclusive(string path) {
            return Open(path, GENERIC_READ | DELETE, 0,
                "Could not reopen held temporary file for exact deletion");
        }

        public static string GetIdentity(SafeFileHandle handle) {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not read held temporary file identity");
            }
            return info.VolumeSerialNumber.ToString("X8") + ":" +
                info.FileIndexHigh.ToString("X8") + info.FileIndexLow.ToString("X8");
        }

        public static void MarkDeletePending(SafeFileHandle handle) {
            FILE_DISPOSITION_INFO info = new FILE_DISPOSITION_INFO { DeleteFile = 1 };
            uint size = (uint)Marshal.SizeOf(typeof(FILE_DISPOSITION_INFO));
            if (!SetFileInformationByHandle(handle, FileDispositionInfo, ref info, size)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(),
                    "Could not mark held temporary file delete-pending");
            }
        }
    }
}
'@
}

function Open-MinicondaHeldTemporaryFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    Initialize-MinicondaHeldFileApi
    return [MinicondaPythonEnv.NativeHeldFile]::OpenReadHeld(
        [IO.Path]::GetFullPath($Path))
}

function Get-MinicondaHeldTemporaryFileIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    Initialize-MinicondaHeldFileApi
    return [MinicondaPythonEnv.NativeHeldFile]::GetIdentity($Stream.SafeFileHandle)
}

function Remove-HeldTemporaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileStream]$Stream,
        [Parameter(Mandatory = $true)][string]$ExpectedFingerprint,
        [Parameter(Mandatory = $true)][string]$ExpectedFileIdentity,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = [IO.Path]::GetFullPath($Path)
    $heldIdentity = $null
    try {
        $actualFingerprint = Get-OpenFileStreamSha256 $Stream
        if ($actualFingerprint -cne $ExpectedFingerprint) {
            throw "$Label changed while its read handle was held; preserving it: $full"
        }
        $heldIdentity = Get-MinicondaHeldTemporaryFileIdentity $Stream
        if ($heldIdentity -cne $ExpectedFileIdentity) {
            throw "$Label file identity changed while its read handle was held; preserving it: $full"
        }
    }
    finally {
        $Stream.Dispose()
    }

    # The read holder prevented rename/delete while Conda was active. Reopen the
    # path exclusively with DELETE access, then compare the kernel file identity
    # before deleting through that exact handle. A substitution in the narrow
    # close/reopen window is preserved and reported rather than deleted.
    $deleteStream = $null
    try {
        Initialize-MinicondaHeldFileApi
        $deleteStream = [MinicondaPythonEnv.NativeHeldFile]::OpenReadDeleteExclusive($full)
        $deleteIdentity = Get-MinicondaHeldTemporaryFileIdentity $deleteStream
        if ($deleteIdentity -cne $ExpectedFileIdentity) {
            throw "$Label path was substituted before cleanup; preserving the replacement: $full"
        }
        if ((Get-OpenFileStreamSha256 $deleteStream) -cne $ExpectedFingerprint) {
            throw "$Label bytes changed before cleanup; preserving the file: $full"
        }
        [MinicondaPythonEnv.NativeHeldFile]::MarkDeletePending($deleteStream.SafeFileHandle)
    }
    finally {
        if ($deleteStream) { $deleteStream.Dispose() }
    }
    if (Get-LiteralWindowsNamespaceEntry -Path $full) {
        throw "$Label survived exact handle delete-pending cleanup: $full"
    }
}

function Get-MinimalCondaConfigurationBytes {
    [CmdletBinding()]
    param()

    return (New-Object Text.UTF8Encoding($false, $true)).GetBytes(
        "channel_alias: https://conda.anaconda.org`nchannels: []`ndefault_channels: []`ncustom_channels: {}`ncustom_multichannels: {}`ncreate_default_packages: []`npinned_packages: []`n")
}

function New-CondaProjectExecutionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [switch]$UseInheritedConfiguration
    )

    $manifestFull = [IO.Path]::GetFullPath($ManifestPath)
    Assert-NoReparseInExistingPath $manifestFull 'PROJECT manifest'
    $manifestStream = $null
    $condarcStream = $null
    $condarcWriteStream = $null
    $condarc = $null
    $condarcFingerprint = $null
    $condarcFileIdentity = $null
    try {
        $manifestStream = [IO.File]::Open($manifestFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $memory = New-Object IO.MemoryStream
        try {
            $manifestStream.CopyTo($memory)
            $manifestBytes = $memory.ToArray()
        }
        finally { $memory.Dispose() }
        $manifestText = (New-Object Text.UTF8Encoding($false, $true)).GetString($manifestBytes)
        foreach ($urlMatch in [regex]::Matches($manifestText, 'https://[^\s''"\],}]+', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $manifestUri = $null
            if ([Uri]::TryCreate($urlMatch.Value, [UriKind]::Absolute, [ref]$manifestUri) -and
                (-not [string]::IsNullOrWhiteSpace($manifestUri.UserInfo) -or
                 -not [string]::IsNullOrWhiteSpace($manifestUri.Query) -or
                 -not [string]::IsNullOrWhiteSpace($manifestUri.Fragment) -or
                 $manifestUri.AbsolutePath -match '(?i)(?:^|/)t/[^/]+')) {
                throw 'PROJECT manifest embeds URL credentials, a token path, query, or fragment; move secrets into an external credential store before preview.'
            }
        }
        $manifestFingerprint = ConvertTo-Sha256Hex $manifestBytes
        $manifestStream.Position = 0
        $manifestParent = Split-Path -Parent $manifestFull
        if (-not $UseInheritedConfiguration) {
            $null = Get-IsolatableProjectManifestChannels $manifestFull
            $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            Assert-NoReparseInExistingPath $tempRoot 'temporary CONDARC root'
            $condarc = Join-Path $tempRoot ("miniconda-python-env-condarc-$([guid]::NewGuid().ToString('N')).yml")
            $condarcBytes = Get-MinimalCondaConfigurationBytes
            $condarcFingerprint = ConvertTo-Sha256Hex $condarcBytes
            $condarcWriteStream = [IO.File]::Open($condarc, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $condarcWriteStream.Write($condarcBytes, 0, $condarcBytes.Length)
            $condarcWriteStream.Flush($true)
            if ((Get-OpenFileStreamSha256 $condarcWriteStream) -cne $condarcFingerprint) {
                throw 'Minimal CONDARC bytes changed during their exclusive write.'
            }
            $condarcFileIdentity = Get-MinicondaHeldTemporaryFileIdentity $condarcWriteStream
            $condarcWriteStream.Dispose()
            $condarcWriteStream = $null
            if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                $env:MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD -eq '1') {
                Remove-Item -LiteralPath $condarc -Force
                [IO.File]::WriteAllBytes($condarc, $condarcBytes)
            }
            # FileShare.Read lets conda read while blocking write/delete/rename
            # and same-name substitution for the whole child operation.
            $condarcStream = Open-MinicondaHeldTemporaryFile -Path $condarc
            $heldCondarcIdentity = Get-MinicondaHeldTemporaryFileIdentity $condarcStream
            if ($heldCondarcIdentity -cne $condarcFileIdentity) {
                throw 'Minimal CONDARC file identity changed before its held read was established.'
            }
            if ((Get-OpenFileStreamSha256 $condarcStream) -cne $condarcFingerprint) {
                throw 'Minimal CONDARC changed before its held read was established.'
            }
        }
        return [PSCustomObject]@{
            ManifestPath = $manifestFull
            ExecutionManifestPath = $manifestFull
            ManifestFingerprint = $manifestFingerprint
            ManifestStream = $manifestStream
            WorkingDirectory = $manifestParent
            UseInheritedConfiguration = [bool]$UseInheritedConfiguration
            CondarcPath = $condarc
            CondarcFingerprint = $condarcFingerprint
            CondarcFileIdentity = $condarcFileIdentity
            CondarcStream = $condarcStream
        }
    }
    catch {
        $originalError = $_
        if ($condarcWriteStream) { $condarcWriteStream.Dispose() }
        if ($manifestStream) { $manifestStream.Dispose() }
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        if ($condarcStream) {
            try {
                Remove-HeldTemporaryFile -Path $condarc -Stream $condarcStream `
                    -ExpectedFingerprint $condarcFingerprint `
                    -ExpectedFileIdentity $condarcFileIdentity -Label 'Failed minimal CONDARC'
                $condarcStream = $null
            }
            catch { $cleanupErrors.Add($_.Exception.Message) }
        }
        elseif ($condarc -and (Test-Path -LiteralPath $condarc)) {
            # A failure before the held read was established leaves ownership
            # uncertain after the exclusive writer closed. Fail closed: retain
            # the random file and report it instead of deleting a replacement.
            $cleanupErrors.Add("Unverified partial minimal CONDARC was preserved: $condarc")
        }
        if ($cleanupErrors.Count) {
            throw "Conda PROJECT context setup and cleanup both failed. Original: $($originalError.Exception.Message) Cleanup: $($cleanupErrors -join ' | ')"
        }
        throw $originalError
    }
}

function New-IsolatedCondaExecutionContext {
    [CmdletBinding()]
    param([AllowNull()][string]$WorkingDirectory)

    $workingFull = $null
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $workingFull = Resolve-SafeLiteralWindowsPath -Value $WorkingDirectory `
            -Name 'isolated conda working directory' -RequireExisting -ExistingType Directory
    }
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-NoReparseInExistingPath $tempRoot 'temporary CONDARC root'
    $condarc = Join-Path $tempRoot ("miniconda-python-env-condarc-$([guid]::NewGuid().ToString('N')).yml")
    $condarcBytes = Get-MinimalCondaConfigurationBytes
    $condarcFingerprint = ConvertTo-Sha256Hex $condarcBytes
    $condarcFileIdentity = $null
    $writeStream = $null
    $readStream = $null
    try {
        $writeStream = [IO.File]::Open($condarc, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $writeStream.Write($condarcBytes, 0, $condarcBytes.Length)
        $writeStream.Flush($true)
        if ((Get-OpenFileStreamSha256 $writeStream) -cne $condarcFingerprint) {
            throw 'Minimal CONDARC bytes changed during their exclusive write.'
        }
        $condarcFileIdentity = Get-MinicondaHeldTemporaryFileIdentity $writeStream
        $writeStream.Dispose()
        $writeStream = $null
        if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
            $env:MINICONDA_PYTHON_ENV_CONDARC_TEST_SUBSTITUTE_BEFORE_HOLD -eq '1') {
            Remove-Item -LiteralPath $condarc -Force
            [IO.File]::WriteAllBytes($condarc, $condarcBytes)
        }
        # Let the child read the policy while preventing replacement for the
        # complete native operation.
        $readStream = Open-MinicondaHeldTemporaryFile -Path $condarc
        $heldCondarcIdentity = Get-MinicondaHeldTemporaryFileIdentity $readStream
        if ($heldCondarcIdentity -cne $condarcFileIdentity) {
            throw 'Minimal CONDARC file identity changed before its held read was established.'
        }
        if ((Get-OpenFileStreamSha256 $readStream) -cne $condarcFingerprint) {
            throw 'Minimal CONDARC changed before its held read was established.'
        }
        return [PSCustomObject]@{
            ManifestPath = $null
            ExecutionManifestPath = $null
            ManifestFingerprint = $null
            ManifestStream = $null
            WorkingDirectory = $workingFull
            UseInheritedConfiguration = $false
            CondarcPath = $condarc
            CondarcFingerprint = $condarcFingerprint
            CondarcFileIdentity = $condarcFileIdentity
            CondarcStream = $readStream
        }
    }
    catch {
        $originalError = $_
        if ($writeStream) { $writeStream.Dispose() }
        $cleanupErrors = New-Object System.Collections.Generic.List[string]
        if ($readStream) {
            try {
                Remove-HeldTemporaryFile -Path $condarc -Stream $readStream `
                    -ExpectedFingerprint $condarcFingerprint `
                    -ExpectedFileIdentity $condarcFileIdentity -Label 'Failed minimal CONDARC'
                $readStream = $null
            }
            catch { $cleanupErrors.Add($_.Exception.Message) }
        }
        elseif (Test-Path -LiteralPath $condarc) {
            # Once the exclusive writer is gone, ownership of a same-name
            # replacement is uncertain. Preserve it for manual recovery.
            $cleanupErrors.Add("Unverified partial minimal CONDARC was preserved: $condarc")
        }
        if ($cleanupErrors.Count) {
            throw "Isolated conda context setup and cleanup both failed. Original: $($originalError.Exception.Message) Cleanup: $($cleanupErrors -join ' | ')"
        }
        throw $originalError
    }
}

function Close-CondaExecutionContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    $cleanupErrors = New-Object System.Collections.Generic.List[string]
    if ($Context.ManifestStream) { $Context.ManifestStream.Dispose() }
    if ($Context.CondarcStream) {
        try {
            Remove-HeldTemporaryFile -Path ([string]$Context.CondarcPath) `
                -Stream $Context.CondarcStream -ExpectedFingerprint ([string]$Context.CondarcFingerprint) `
                -ExpectedFileIdentity ([string]$Context.CondarcFileIdentity) `
                -Label 'Held minimal CONDARC cleanup'
        }
        catch { $cleanupErrors.Add($_.Exception.Message) }
    }
    if ($cleanupErrors.Count) {
        throw "Conda PROJECT context cleanup failed: $($cleanupErrors -join ' | ')"
    }
}

function Close-CondaProjectExecutionContext {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    Close-CondaExecutionContext -Context $Context
}

function Invoke-WithIsolatedCondaExecutionContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$WorkingDirectory
    )

    $context = $null
    $output = $null
    $operationError = $null
    $cleanupError = $null
    try {
        $context = New-IsolatedCondaExecutionContext -WorkingDirectory $WorkingDirectory
        $output = & $Operation $context
    }
    catch { $operationError = $_ }
    finally {
        if ($context) {
            try { Close-CondaExecutionContext -Context $context }
            catch { $cleanupError = $_ }
        }
    }
    if ($operationError -and $cleanupError) {
        throw "$Label failed and isolated CONDARC cleanup also failed. Original: $($operationError.Exception.Message) Cleanup: $($cleanupError.Exception.Message)"
    }
    if ($operationError) { throw $operationError }
    if ($cleanupError) { throw $cleanupError }
    return $output
}

function Invoke-CondaProjectChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $childEnvironment = @{ CI = 'false'; CONDA_PLUGINS_AUTO_ACCEPT_TOS = 'false' }
    if ($Context.CondarcPath) { $childEnvironment.CONDARC = $Context.CondarcPath }
    $ciNames = 'CI|APPVEYOR|BITRISE_IO|BUDDY|BUILDKITE|CIRCLECI|CIRRUS_CI|CONCOURSE_CI|DRONE|GITHUB_ACTIONS|GITLAB_CI|SAIL_CI|SEMAPHORE|TRAVIS|WOODPECKER_CI|HEROKU_TEST_RUN_ID|JENKINS_URL|TEAMCITY_VERSION'
    $removePattern = if ($Context.CondarcPath) {
        "^(?:CONDA_|_CE_|PYTHONHOME$|PYTHONPATH$|$ciNames`$)"
    } else {
        "^(?:CONDA_PLUGINS_AUTO_ACCEPT_TOS`$|_CE_|PYTHONHOME$|PYTHONPATH$|$ciNames`$)"
    }
    return Invoke-ProcessCapturedChecked -FilePath $CondaExe -ArgumentList $ArgumentList `
        -Environment $childEnvironment -RemoveEnvironmentNamePattern $removePattern `
        -WorkingDirectory ([string]$Context.WorkingDirectory) -Label $Label
}

function ConvertTo-RedactedCondaPlanSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('channel', 'base_url', 'url')][string]$FieldName
    )

    $FieldName = $FieldName.ToLowerInvariant()
    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
    $uri = $null
    if ([Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$uri) -and $uri.IsAbsoluteUri) {
        $segments = New-Object System.Collections.Generic.List[string]
        foreach ($segment in @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })) {
            $segments.Add([Uri]::UnescapeDataString($segment))
        }
        for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
            if ($segments[$index] -ceq 't') {
                $segments.RemoveAt($index + 1) # redact anaconda.org token path component
                $segments[$index] = 't'
                $segments.Insert($index + 1, '<redacted>')
                break
            }
        }
        if ($FieldName -ceq 'url' -and $segments.Count -gt 0 -and
            $segments[$segments.Count - 1] -match '(?:\.conda|\.tar\.bz2)$') {
            $segments.RemoveAt($segments.Count - 1)
            if ($segments.Count -gt 0 -and
                $segments[$segments.Count - 1] -match '^(?:noarch|(?:win|linux|osx|freebsd|emscripten|wasi|zos)-[A-Za-z0-9_]+)$') {
                $segments.RemoveAt($segments.Count - 1)
            }
        }
        if ($uri.Scheme -ceq 'file') {
            if (-not [string]::IsNullOrWhiteSpace($uri.Host) -and $uri.Host -cne 'localhost') {
                return 'file://' + $uri.Host.ToLowerInvariant() + '/' + ($segments -join '/')
            }
            return 'file:///' + ($segments -join '/')
        }
        $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
        $origin = "$($uri.Scheme.ToLowerInvariant())://$($uri.IdnHost.ToLowerInvariant())$port"
        if ($segments.Count -gt 0) { return "$origin/$($segments -join '/')" }
        return $origin
    }
    if ($trimmed -match '^[A-Za-z]:[\\/]' -or $trimmed.StartsWith('\\')) {
        $full = [IO.Path]::GetFullPath($trimmed)
        if ($FieldName -ceq 'url') { return Split-Path -Parent $full }
        return $full
    }
    return $trimmed
}

function Get-CondaJsonPropertyValue {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ceq $Name) { return $Object[$key] }
        }
        return $null
    }
    $property = @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name }) | Select-Object -First 1
    if ($property) { return $property.Value }
    return $null
}

function ConvertFrom-CondaChannelObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Channel)

    if ($Channel -is [string]) {
        return ConvertTo-RedactedCondaPlanSource -Value $Channel -FieldName base_url
    }
    $scheme = [string](Get-CondaJsonPropertyValue $Channel 'scheme')
    $location = [string](Get-CondaJsonPropertyValue $Channel 'location')
    $name = [string](Get-CondaJsonPropertyValue $Channel 'name')
    $token = [string](Get-CondaJsonPropertyValue $Channel 'token')
    if ([string]::IsNullOrWhiteSpace($scheme)) { $scheme = 'https' }
    if ([string]::IsNullOrWhiteSpace($location)) { throw 'Conda channel configuration has no location.' }
    $value = "${scheme}://$location"
    if (-not [string]::IsNullOrWhiteSpace($token)) { $value += '/t/<redacted>' }
    if (-not [string]::IsNullOrWhiteSpace($name)) { $value += '/' + $name.Trim('/') }
    return ConvertTo-RedactedCondaPlanSource -Value $value -FieldName base_url
}

function Resolve-CondaPlannedChannel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identifier,
        [Parameter(Mandatory = $true)]$Configuration
    )

    $identifierValue = $Identifier.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($identifierValue) -or $identifierValue -ceq 'nodefaults') { return @() }
    $uri = $null
    if ([Uri]::TryCreate($identifierValue, [UriKind]::Absolute, [ref]$uri) -and $uri.IsAbsoluteUri) {
        return @(ConvertTo-RedactedCondaPlanSource -Value $identifierValue -FieldName base_url)
    }
    if ($identifierValue -match '^[A-Za-z]:[\\/]' -or $identifierValue.StartsWith('\\')) {
        return @(ConvertTo-RedactedCondaPlanSource -Value $identifierValue -FieldName base_url)
    }

    $multiChannels = Get-CondaJsonPropertyValue $Configuration 'custom_multichannels'
    $multi = Get-CondaJsonPropertyValue $multiChannels $identifierValue
    if ($null -ne $multi) {
        $resolved = New-Object System.Collections.Generic.List[string]
        foreach ($channel in @($multi)) { $resolved.Add((ConvertFrom-CondaChannelObject $channel)) }
        if ($resolved.Count -eq 0) { throw "Conda multichannel '$identifierValue' resolved to no source." }
        return @($resolved)
    }
    if ($identifierValue -ceq 'defaults') {
        $defaults = @(Get-CondaJsonPropertyValue $Configuration 'default_channels')
        if ($defaults.Count -gt 0) {
            $resolved = New-Object System.Collections.Generic.List[string]
            foreach ($channel in $defaults) { $resolved.Add((ConvertFrom-CondaChannelObject $channel)) }
            return @($resolved)
        }
    }

    $customChannels = Get-CondaJsonPropertyValue $Configuration 'custom_channels'
    $custom = Get-CondaJsonPropertyValue $customChannels $identifierValue
    if ($null -ne $custom) { return @(ConvertFrom-CondaChannelObject $custom) }
    if ($customChannels) {
        $prefixProperty = @($customChannels.PSObject.Properties | Where-Object {
            $identifierValue.StartsWith($_.Name + '/', [StringComparison]::Ordinal)
        } | Sort-Object { $_.Name.Length } -Descending) | Select-Object -First 1
        if ($prefixProperty) {
            $base = ConvertFrom-CondaChannelObject $prefixProperty.Value
            $remainder = $identifierValue.Substring($prefixProperty.Name.Length).TrimStart('/')
            return @(ConvertTo-RedactedCondaPlanSource -Value ($base.TrimEnd('/') + '/' + $remainder) -FieldName base_url)
        }
    }

    $alias = Get-CondaJsonPropertyValue $Configuration 'channel_alias'
    if ($null -eq $alias) { throw "Conda channel '$identifierValue' has no resolvable channel_alias." }
    $aliasValue = ConvertFrom-CondaChannelObject $alias
    return @(ConvertTo-RedactedCondaPlanSource -Value ($aliasValue.TrimEnd('/') + '/' + $identifierValue) -FieldName base_url)
}

function Get-CondaPlanState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][string]$ChannelConfigurationJson
    )

    try { $parsed = $Json | ConvertFrom-Json }
    catch { throw "Conda dry-run did not return valid JSON: $($_.Exception.Message)" }
    try { $configuration = $ChannelConfigurationJson | ConvertFrom-Json }
    catch { throw "Conda channel configuration did not return valid JSON: $($_.Exception.Message)" }
    $canonical = $parsed | ConvertTo-Json -Depth 100 -Compress
    $configurationCanonical = $configuration | ConvertTo-Json -Depth 100 -Compress
    $configurationFingerprint = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($configurationCanonical))
    $fingerprint = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes(
        $canonical + "`n" + $configurationCanonical))
    $sources = New-Object System.Collections.Generic.List[string]
    $plannedChannels = New-Object System.Collections.Generic.List[string]
    $pipEntries = New-Object System.Collections.Generic.List[string]
    $pythonVersions = New-Object System.Collections.Generic.List[string]
    foreach ($channel in @($parsed.channels)) {
        if ($channel -is [string] -and -not $plannedChannels.Contains([string]$channel)) {
            $plannedChannels.Add([string]$channel)
        }
    }
    foreach ($dependency in @($parsed.dependencies)) {
        if ($dependency -is [string] -and $dependency -match '(?:^|::)python==(?<version>[0-9]+\.[0-9]+(?:\.[0-9]+)?)=') {
            if (-not $pythonVersions.Contains([string]$Matches.version)) { $pythonVersions.Add([string]$Matches.version) }
        }
        if ($dependency -is [string] -and
            $dependency -match '^(?<channel>.+?)/(?:noarch|(?:win|linux|osx|freebsd|emscripten|wasi|zos)-[A-Za-z0-9_]+)::') {
            $channel = [string]$Matches.channel
            if (-not $plannedChannels.Contains($channel)) { $plannedChannels.Add($channel) }
        }
        elseif ($null -ne $dependency -and -not ($dependency -is [string])) {
            foreach ($property in @($dependency.PSObject.Properties)) {
                if ($property.Name -cne 'pip') {
                    throw "Unsupported PROJECT dependency mapping '$($property.Name)' in conda dry-run output."
                }
                foreach ($entry in @($property.Value)) { if ($entry -is [string]) { $pipEntries.Add($entry) } }
            }
        }
    }
    if ($pipEntries.Count) {
        throw 'PROJECT environment.yml pip sections are not source-bound by conda dry-run; remove that section, re-preview, and handle pip requirements only through a separate explicit post-creation approval.'
    }
    foreach ($linked in @($parsed.actions.LINK)) {
        if ([string](Get-CondaJsonPropertyValue $linked 'name') -ceq 'python') {
            $version = [string](Get-CondaJsonPropertyValue $linked 'version')
            if (-not [string]::IsNullOrWhiteSpace($version) -and -not $pythonVersions.Contains($version)) {
                $pythonVersions.Add($version)
            }
        }
    }
    if ($pythonVersions.Count -ne 1) {
        throw 'PROJECT solve preview must resolve exactly one Python package/version.'
    }
    $pythonParts = $pythonVersions[0] -split '\.'
    $pythonMajorMinor = $pythonParts[0] + '.' + $pythonParts[1]
    $pending = New-Object System.Collections.Stack
    $pending.Push($parsed)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        if ($null -eq $current) { continue }
        if ($current -is [Collections.IDictionary]) {
            foreach ($key in $current.Keys) {
                $value = $current[$key]
                if ([string]$key -in @('channel', 'base_url', 'url') -and $value -is [string]) {
                    $candidate = [string]$value
                    if ($candidate -match '^(?:[A-Za-z][A-Za-z0-9+.-]*://|[A-Za-z]:[\\/]|\\\\)') {
                        $source = ConvertTo-RedactedCondaPlanSource -Value $candidate -FieldName ([string]$key)
                        if ($source -and -not $sources.Contains($source)) { $sources.Add($source) }
                    }
                    elseif (-not $plannedChannels.Contains($candidate)) { $plannedChannels.Add($candidate) }
                }
                elseif ($null -ne $value -and -not ($value -is [string])) { $pending.Push($value) }
            }
            continue
        }
        if ($current -is [Collections.IEnumerable] -and -not ($current -is [string])) {
            foreach ($item in $current) { if ($null -ne $item) { $pending.Push($item) } }
            continue
        }
        if ($current -isnot [Management.Automation.PSCustomObject]) { continue }
        foreach ($property in @($current.PSObject.Properties)) {
            $value = $property.Value
            if ($property.Name -in @('channel', 'base_url', 'url') -and $value -is [string]) {
                $candidate = [string]$value
                if ($candidate -match '^(?:[A-Za-z][A-Za-z0-9+.-]*://|[A-Za-z]:[\\/]|\\\\)') {
                    $source = ConvertTo-RedactedCondaPlanSource -Value $candidate -FieldName $property.Name
                    if ($source -and -not $sources.Contains($source)) { $sources.Add($source) }
                }
                elseif (-not $plannedChannels.Contains($candidate)) { $plannedChannels.Add($candidate) }
            }
            elseif ($null -ne $value -and -not ($value -is [string])) { $pending.Push($value) }
        }
    }
    foreach ($plannedChannel in @($plannedChannels)) {
        foreach ($source in @(Resolve-CondaPlannedChannel -Identifier $plannedChannel -Configuration $configuration)) {
            if ($source -and -not $sources.Contains($source)) { $sources.Add($source) }
        }
    }
    $packageCount = @($parsed.actions.LINK | Where-Object { $null -ne $_ }).Count
    if ($packageCount -eq 0 -and $null -ne $parsed.dependencies) {
        foreach ($dependency in @($parsed.dependencies)) {
            if ($dependency -is [string]) { $packageCount++ }
        }
    }
    if ($packageCount -gt 0 -and $sources.Count -eq 0) {
        throw 'Conda dry-run planned packages but exposed no resolvable channel source.'
    }
    return [PSCustomObject]@{
        Fingerprint = $fingerprint
        ChannelConfigurationFingerprint = $configurationFingerprint
        ResolvedSources = @($sources | Sort-Object -Unique)
        PlannedChannels = @($plannedChannels)
        VariableNames = @($parsed.variables.PSObject.Properties.Name | Sort-Object -Unique)
        PythonVersion = $pythonVersions[0]
        PythonMajorMinor = $pythonMajorMinor
        PackageCount = $packageCount
    }
}

function Get-CondaProjectPlanPreviewState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    $solvePath = Join-Path (Split-Path -Parent $envFull) `
        ('.' + (Split-Path -Leaf $envFull) + '.miniconda-python-env-solve')
    $solveLock = Enter-ManagedEnvironmentMutex -EnvPath $solvePath
    try {
        Assert-NoReparseInExistingPath (Split-Path -Parent $solvePath) "$Label solve root"
        if (Test-Path -LiteralPath $solvePath) {
            throw "Dedicated conda solve prefix already exists; refusing to reuse or delete it: $solvePath"
        }
        $configArguments = @('config', '--show', 'channel_alias', 'default_channels',
            'custom_channels', 'custom_multichannels', 'channels', '--json')
        $configurationBefore = Invoke-CondaProjectChild -CondaExe $CondaExe -Context $Context `
            -ArgumentList $configArguments -Label "$Label channel policy (before)"
        $json = Invoke-CondaProjectChild -CondaExe $CondaExe -Context $Context `
            -ArgumentList @('env', 'create', '--prefix', $solvePath, '--file',
                $Context.ExecutionManifestPath, '--environment-specifier', 'environment.yml',
                '--no-default-packages', '--dry-run', '--json', '-y') `
            -Label $Label
        $configurationAfter = Invoke-CondaProjectChild -CondaExe $CondaExe -Context $Context `
            -ArgumentList $configArguments -Label "$Label channel policy (after)"
        if (Test-Path -LiteralPath $solvePath) {
            throw "Conda dry-run unexpectedly created its dedicated solve prefix; it was preserved for inspection: $solvePath"
        }
    }
    finally { Exit-ManagedEnvironmentMutex $solveLock }
    try {
        $beforeCanonical = ($configurationBefore | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress
        $afterCanonical = ($configurationAfter | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress
    }
    catch { throw "Conda channel policy probe did not return valid JSON: $($_.Exception.Message)" }
    if ($beforeCanonical -cne $afterCanonical) {
        throw 'Conda channel configuration changed during the solve preview; retry and reconfirm.'
    }
    return Get-CondaPlanState -Json $json -ChannelConfigurationJson $configurationAfter
}

function Get-CondaProjectApprovalFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][bool]$UseInheritedConfiguration,
        [Parameter(Mandatory = $true)][string]$ManifestFingerprint,
        [Parameter(Mandatory = $true)]$Plan
    )

    $payload = [ordered]@{
        ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
        EnvPath = [IO.Path]::GetFullPath($EnvPath)
        CondaExe = [IO.Path]::GetFullPath($CondaExe)
        UseInheritedConfiguration = $UseInheritedConfiguration
        ManifestFingerprint = $ManifestFingerprint
        PlanFingerprint = [string]$Plan.Fingerprint
        ChannelConfigurationFingerprint = [string]$Plan.ChannelConfigurationFingerprint
        ResolvedSources = @($Plan.ResolvedSources)
        PlannedChannels = @($Plan.PlannedChannels)
        VariableNames = @($Plan.VariableNames)
        PythonVersion = [string]$Plan.PythonVersion
        PythonMajorMinor = [string]$Plan.PythonMajorMinor
        PackageCount = [int]$Plan.PackageCount
    }
    $canonical = $payload | ConvertTo-Json -Depth 20 -Compress
    return ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
}

function Assert-CondaProjectManifestHasNoExternalInstallers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)]$Context
    )

    $condaFull = Resolve-SafeLiteralWindowsPath -Value $CondaExe `
        -Name 'Conda executable' -RequireExisting -ExistingType File
    $manifestFull = Resolve-SafeLiteralWindowsPath -Value ([string]$Context.ManifestPath) `
        -Name 'PROJECT manifest' -RequireExisting -ExistingType File
    if (-not $Context.ManifestStream) {
        throw 'PROJECT external-installer policy requires a held manifest stream.'
    }
    $infoJson = Invoke-WithIsolatedCondaExecutionContext `
        -Label 'Conda identity policy probe' -Operation {
            param($identityContext)
            Invoke-CondaProjectChild -CondaExe $condaFull -Context $identityContext `
                -ArgumentList @('info', '--json') -Label 'conda identity policy probe'
        }
    try { $info = $infoJson | ConvertFrom-Json }
    catch { throw "Conda identity policy probe returned invalid JSON: $($_.Exception.Message)" }
    $rootPrefix = [string]$info.root_prefix
    if ([string]::IsNullOrWhiteSpace($rootPrefix) -or -not [IO.Path]::IsPathRooted($rootPrefix)) {
        throw 'Conda identity policy probe returned no rooted root_prefix.'
    }
    $rootFull = Resolve-SafeLiteralWindowsPath -Value $rootPrefix `
        -Name 'Conda root prefix' -RequireExisting -ExistingType Directory
    $rootPython = Resolve-SafeLiteralWindowsPath -Value (Join-Path $rootFull 'python.exe') `
        -Name 'Conda root Python parser' -RequireExisting -ExistingType File
    $parserCode = @'
import json
import sys
import warnings

warnings.simplefilter("ignore")
from conda.env.specs.yaml_file import YamlFileSpec

spec = YamlFileSpec(filename=sys.argv[1])
if not spec.can_handle():
    raise RuntimeError("Conda's YAML parser rejected the PROJECT manifest")
try:
    environment = spec.env
except (AttributeError, NotImplementedError):
    environment = spec.environment
external = getattr(environment, "external_packages", None)
if external is None:
    dependencies = getattr(environment, "dependencies", None)
    if not isinstance(dependencies, dict):
        raise RuntimeError("Unsupported conda manifest parser API: no external package mapping")
    external = {"pip": dependencies.get("pip", [])} if dependencies.get("pip") else {}
if not isinstance(external, dict):
    raise RuntimeError("Conda's parsed environment exposed an invalid external package mapping")
variables = getattr(environment, "variables", None) or {}
if not isinstance(variables, dict):
    raise RuntimeError("Conda's parsed environment exposed an invalid variables mapping")
active = sorted(str(name) for name, packages in external.items() if packages)
print(json.dumps({"external_installers": active, "variable_names": sorted(str(name) for name in variables)}, separators=(",", ":")))
'@
    $stateJson = Invoke-ProcessCapturedChecked -FilePath $rootPython `
        -ArgumentList @('-I', '-c', $parserCode, $manifestFull) `
        -RemoveEnvironmentNamePattern '^(?:CONDA_|_CE_|PYTHONHOME$|PYTHONPATH$)' `
        -WorkingDirectory (Split-Path -Parent $manifestFull) `
        -Label 'Conda PROJECT manifest structure parser'
    try { $state = $stateJson | ConvertFrom-Json }
    catch { throw "Conda PROJECT manifest structure parser returned invalid JSON: $($_.Exception.Message)" }
    $externalInstallers = @($state.external_installers | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($externalInstallers.Count) {
        throw "PROJECT environment.yml external installer sections are not source-bound by conda dry-run; remove: $($externalInstallers -join ', ')"
    }
    $variableNames = @($state.variable_names | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | ForEach-Object { [string]$_ })
    if ($variableNames.Count) {
        throw "PROJECT environment.yml variables are unsupported because direct interpreter execution does not activate conda environment variables; remove: $($variableNames -join ', ')"
    }
    return [PSCustomObject]@{
        ExternalInstallers = @($externalInstallers)
        VariableNames = @()
    }
}

function Get-CondaProjectEnvironmentPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [switch]$UseInheritedConfiguration
    )

    $condaFull = [IO.Path]::GetFullPath($CondaExe)
    $envFull = [IO.Path]::GetFullPath($EnvPath)
    $context = New-CondaProjectExecutionContext -ManifestPath $ManifestPath `
        -UseInheritedConfiguration:$UseInheritedConfiguration
    $originalError = $null
    try {
        $manifestPolicy = Assert-CondaProjectManifestHasNoExternalInstallers `
            -CondaExe $condaFull -Context $context
        $plan = Get-CondaProjectPlanPreviewState -CondaExe $condaFull -EnvPath $envFull `
            -Context $context -Label 'conda PROJECT dry-run preview'
        $plan.VariableNames = @($manifestPolicy.VariableNames)
        $preview = [PSCustomObject]@{
            ManifestPath = $context.ManifestPath
            EnvPath = $envFull
            CondaExe = $condaFull
            UseInheritedConfiguration = [bool]$UseInheritedConfiguration
            ManifestFingerprint = $context.ManifestFingerprint
            PlanFingerprint = $plan.Fingerprint
            ChannelConfigurationFingerprint = $plan.ChannelConfigurationFingerprint
            ResolvedSources = $plan.ResolvedSources
            PlannedChannels = $plan.PlannedChannels
            VariableNames = $plan.VariableNames
            PythonVersion = $plan.PythonVersion
            PythonMajorMinor = $plan.PythonMajorMinor
            PackageCount = $plan.PackageCount
        }
        $preview | Add-Member -NotePropertyName ApprovalFingerprint -NotePropertyValue `
            (Get-CondaProjectApprovalFingerprint -ManifestPath $preview.ManifestPath -EnvPath $preview.EnvPath `
                -CondaExe $preview.CondaExe `
                -UseInheritedConfiguration $preview.UseInheritedConfiguration `
                -ManifestFingerprint $preview.ManifestFingerprint -Plan $plan)
        return $preview
    }
    catch { $originalError = $_ }
    finally {
        try { Close-CondaProjectExecutionContext $context }
        catch {
            if ($originalError) {
                throw "Conda preview and cleanup both failed. Original: $($originalError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
            throw
        }
    }
    throw $originalError
}

function Invoke-WithManagedEnvironmentMarkerProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Claim,
        [Parameter(Mandatory = $true)]
        [ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $envFull = ConvertTo-CanonicalWindowsPath $EnvPath
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle `
        -EnvPath $envFull
    $markerPath = [IO.Path]::GetFullPath([string]$Claim.MarkerPath)
    $markerBytes = [IO.File]::ReadAllBytes($markerPath)
    $operationError = $null
    try { $output = & $Operation }
    catch { $operationError = $_ }
    if ((Test-Path -LiteralPath $envFull -PathType Container) -and
        -not (Test-Path -LiteralPath $markerPath)) {
        try {
            $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle `
                -EnvPath $envFull -AllowMissingMarkerIfEnvironmentExists
            $restoreStream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $restoreStream.Write($markerBytes, 0, $markerBytes.Length)
                $restoreStream.Flush($true)
            }
            finally { $restoreStream.Dispose() }
        }
        catch {
            if ($operationError) {
                throw "$Label and marker rollback both failed. Original: $($operationError.Exception.Message) Rollback: $($_.Exception.Message)"
            }
            throw
        }
    }
    if ($operationError) { throw $operationError }
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle `
        -EnvPath $envFull
    return $output
}

function Invoke-CondaEnvironmentCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)]
        [ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)]$Claim
    )

    if ($PythonVersion -cnotmatch '^3\.[0-9]{1,2}$') {
        throw "Python version must be an exact major.minor: $PythonVersion"
    }
    $condaFull = Resolve-SafeLiteralWindowsPath -Value $CondaExe `
        -Name 'Conda executable' -RequireExisting -ExistingType File
    $envFull = ConvertTo-CanonicalWindowsPath $EnvPath
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $envFull
    $output = Invoke-WithIsolatedCondaExecutionContext `
        -Label 'Conda environment creation policy' -Operation {
            param($context)
            Invoke-WithManagedEnvironmentMarkerProtection -Claim $Claim `
                -Lifecycle $Lifecycle -EnvPath $envFull -Label 'Conda environment creation' `
                -Operation {
                    Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                        -ArgumentList @('create', '--prefix', $envFull, "python=$PythonVersion", '-c',
                            'https://conda.anaconda.org/conda-forge', '--override-channels',
                            '--no-default-packages', '-y') -Label 'conda create'
                }
        }
    $pythonExe = Assert-CondaEnvironmentPython -EnvPath $envFull `
        -ExpectedMajorMinor $PythonVersion
    return [PSCustomObject]@{
        Output = $output
        PythonExe = $pythonExe
        EnvPath = $envFull
    }
}

function Invoke-CondaEnvironmentPackageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ApprovedPlan,
        [Parameter(Mandatory = $true)]$Claim
    )

    $locked = Get-LockedCondaEnvironmentCreationPlan -ApprovedPlan $ApprovedPlan
    $packages = @($locked.CondaPackages)
    if ($packages.Count -eq 0) { throw 'At least one approved conda package is required.' }
    $condaFull = [string]$locked.CondaExe
    $envFull = [string]$locked.EnvPath
    $lifecycle = [string]$locked.Lifecycle
    $expectedPython = [string]$locked.PythonVersion
    Assert-ManagedEnvironmentCreationPath -Lifecycle $lifecycle `
        -ManagedRoot ([string]$locked.ManagedRoot) -EnvPath $envFull
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim `
        -Lifecycle $lifecycle -EnvPath $envFull
    $output = Invoke-WithIsolatedCondaExecutionContext `
        -Label 'Conda package installation policy' -Operation {
            param($context)
            Invoke-WithManagedEnvironmentMarkerProtection -Claim $Claim `
                -Lifecycle $lifecycle -EnvPath $envFull -Label 'Conda package installation' `
                -Operation {
                    Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                        -ArgumentList (@('install', '--prefix', $envFull, '-c',
                            'https://conda.anaconda.org/conda-forge', '--override-channels',
                            "python=$expectedPython") +
                            $packages + @('-y')) -Label 'conda install'
                }
        }
    $null = Assert-CondaEnvironmentPython -EnvPath $envFull `
        -ExpectedMajorMinor $expectedPython
    return $output
}

function Invoke-PipEnvironmentPackageInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ApprovedPlan,
        [Parameter(Mandatory = $true)]$Claim
    )

    $locked = Get-LockedCondaEnvironmentCreationPlan -ApprovedPlan $ApprovedPlan
    $packages = @($locked.PipPackages)
    if ($packages.Count -eq 0) { throw 'At least one approved pip package is required.' }
    $envFull = [string]$locked.EnvPath
    $lifecycle = [string]$locked.Lifecycle
    Assert-ManagedEnvironmentCreationPath -Lifecycle $lifecycle `
        -ManagedRoot ([string]$locked.ManagedRoot) -EnvPath $envFull
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim `
        -Lifecycle $lifecycle -EnvPath $envFull
    $pythonExe = Assert-CondaEnvironmentPython -EnvPath $envFull `
        -ExpectedMajorMinor ([string]$locked.PythonVersion)
    $output = Invoke-NativeChecked {
        & $pythonExe -m pip install --isolated `
            --index-url https://pypi.org/simple $packages
    } 'pip install'
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim `
        -Lifecycle $lifecycle -EnvPath $envFull
    $null = Assert-CondaEnvironmentPython -EnvPath $envFull `
        -ExpectedMajorMinor ([string]$locked.PythonVersion)
    return $output
}

function Invoke-CondaProjectEnvironmentCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)]$ApprovedPreview,
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)]$Claim
    )

    $condaFull = [IO.Path]::GetFullPath($CondaExe)
    $envFull = [IO.Path]::GetFullPath($EnvPath)
    $manifestFull = [IO.Path]::GetFullPath($ManifestPath)
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle -ManagedRoot $ManagedRoot -EnvPath $envFull
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
    if (-not ([IO.Path]::GetFullPath([string]$ApprovedPreview.ManifestPath)).Equals($manifestFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFullPath([string]$ApprovedPreview.EnvPath)).Equals($envFull, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFullPath([string]$ApprovedPreview.CondaExe)).Equals($condaFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approved conda preview belongs to a different manifest, prefix, or conda executable.'
    }
    $useInherited = [bool]$ApprovedPreview.UseInheritedConfiguration
    $approvedPlanView = [PSCustomObject]@{
        Fingerprint = [string]$ApprovedPreview.PlanFingerprint
        ChannelConfigurationFingerprint = [string]$ApprovedPreview.ChannelConfigurationFingerprint
        ResolvedSources = @($ApprovedPreview.ResolvedSources)
        PlannedChannels = @($ApprovedPreview.PlannedChannels)
        VariableNames = @($ApprovedPreview.VariableNames)
        PythonVersion = [string]$ApprovedPreview.PythonVersion
        PythonMajorMinor = [string]$ApprovedPreview.PythonMajorMinor
        PackageCount = [int]$ApprovedPreview.PackageCount
    }
    $approvedFingerprint = Get-CondaProjectApprovalFingerprint -ManifestPath $manifestFull -EnvPath $envFull `
        -CondaExe $condaFull `
        -UseInheritedConfiguration $useInherited -ManifestFingerprint ([string]$ApprovedPreview.ManifestFingerprint) `
        -Plan $approvedPlanView
    if ($approvedFingerprint -cne [string]$ApprovedPreview.ApprovalFingerprint) {
        throw 'Approved PROJECT preview record is incomplete or changed; preview and confirmation must be repeated.'
    }
    $context = New-CondaProjectExecutionContext -ManifestPath $manifestFull `
        -UseInheritedConfiguration:$useInherited
    $originalError = $null
    try {
        if ($context.ManifestFingerprint -cne [string]$ApprovedPreview.ManifestFingerprint) {
            throw 'PROJECT environment manifest changed after approval; preview and confirmation must be repeated.'
        }
        $manifestPolicy = Assert-CondaProjectManifestHasNoExternalInstallers `
            -CondaExe $condaFull -Context $context
        $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
        $plan = Get-CondaProjectPlanPreviewState -CondaExe $condaFull -EnvPath $envFull `
            -Context $context -Label 'conda PROJECT approved-plan recheck'
        $plan.VariableNames = @($manifestPolicy.VariableNames)
        if ($plan.Fingerprint -cne [string]$ApprovedPreview.PlanFingerprint) {
            throw 'Conda PROJECT solve plan changed after approval; show the new sources/packages and reconfirm.'
        }
        $currentApproval = Get-CondaProjectApprovalFingerprint -ManifestPath $manifestFull -EnvPath $envFull `
            -CondaExe $condaFull `
            -UseInheritedConfiguration $useInherited -ManifestFingerprint $context.ManifestFingerprint -Plan $plan
        if ($currentApproval -cne [string]$ApprovedPreview.ApprovalFingerprint) {
            throw 'Conda PROJECT approval details no longer match the solve; show the new preview and reconfirm.'
        }
        $creationOutput = Invoke-WithManagedEnvironmentMarkerProtection `
            -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull `
            -Label 'Conda PROJECT environment creation' -Operation {
                Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                    -ArgumentList @('env', 'create', '--prefix', $envFull, '--file',
                        $context.ExecutionManifestPath, '--environment-specifier',
                        'environment.yml', '--no-default-packages', '-y') `
                    -Label 'conda env create from approved project manifest'
            }
        $null = Assert-CondaEnvironmentPython -EnvPath $envFull `
            -ExpectedMajorMinor ([string]$ApprovedPreview.PythonMajorMinor)
        return $creationOutput
    }
    catch { $originalError = $_ }
    finally {
        try { Close-CondaProjectExecutionContext $context }
        catch {
            if ($originalError) {
                throw "Conda creation and cleanup both failed. Original: $($originalError.Exception.Message) Cleanup: $($_.Exception.Message)"
            }
            throw
        }
    }
    throw $originalError
}

function Get-CondaInstalledChannelSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)]$Configuration
    )

    try { $records = @($Json | ConvertFrom-Json) }
    catch { throw "Conda list did not return valid JSON: $($_.Exception.Message)" }
    $sources = New-Object System.Collections.Generic.List[string]
    foreach ($record in $records) {
        $channel = [string](Get-CondaJsonPropertyValue $record 'channel')
        if ($channel -in @('pypi', '<develop>', '')) { continue }
        $baseUrl = [string](Get-CondaJsonPropertyValue $record 'base_url')
        $resolved = if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
            @(ConvertTo-RedactedCondaPlanSource -Value $baseUrl -FieldName base_url)
        } else {
            @(Resolve-CondaPlannedChannel -Identifier $channel -Configuration $Configuration)
        }
        foreach ($source in $resolved) {
            if ($source -and -not $sources.Contains($source)) { $sources.Add($source) }
        }
    }
    return @($sources | Sort-Object -Unique)
}

function Set-CondaYamlChannelPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Yaml,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Channel
    )

    $approved = @($Channel | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -cne 'nodefaults' } |
        Select-Object -Unique)
    if ($approved.Count -eq 0) { throw 'An isolated export has no approved channel to write.' }
    $lines = @($Yaml -split '\r?\n')
    $kept = New-Object System.Collections.Generic.List[string]
    $skippingChannels = $false
    foreach ($line in $lines) {
        if ($line -match '^channels:\s*(?:#.*)?$') { $skippingChannels = $true; continue }
        if ($skippingChannels) {
            if ($line -match '^\s+-\s+' -or $line -match '^\s*(?:#.*)?$') { continue }
            $skippingChannels = $false
        }
        $kept.Add($line)
    }
    $output = New-Object System.Collections.Generic.List[string]
    $output.Add('channels:')
    foreach ($channel in @($approved + 'nodefaults')) {
        $output.Add("  - '" + $channel.Replace("'", "''") + "'")
    }
    foreach ($line in $kept) { $output.Add($line) }
    return ($output -join "`n").TrimEnd() + "`n"
}

function Remove-CondaYamlMachineMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Yaml)

    $kept = New-Object System.Collections.Generic.List[string]
    $skipping = $false
    foreach ($line in @($Yaml -split '\r?\n')) {
        if ($line -match '^(?:name|prefix):(?:\s|$)') {
            $skipping = $true
            continue
        }
        if ($skipping) {
            if ($line -match '^\S') { $skipping = $false } else { continue }
        }
        $kept.Add($line)
    }
    return ($kept -join "`n").TrimEnd() + "`n"
}

function Enter-CondaManifestMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $canonical = [IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $lockId = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical))
    $name = "Global\miniconda-python-env-manifest-$lockId"
    $mutex = New-Object Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
            Write-Warning "Recovered abandoned environment manifest lock '$name'; file state will be revalidated."
        }
        if (-not $acquired) { throw "Timed out waiting for environment manifest lock '$name'." }
        return [PSCustomObject]@{ Mutex = $mutex; Acquired = $true; Name = $name }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-CondaManifestMutex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Lock)

    try { if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() } }
    finally { $Lock.Mutex.Dispose() }
}

function Assert-NoCondaManifestTransactionResidue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    $leaf = Split-Path -Leaf $full
    $pattern = '^\.' + [regex]::Escape($leaf) +
        '\.manifest-(?:stage|replace-backup)-[0-9a-f]{32}$'
    $residue = @(Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop |
        Where-Object { $_.Name -match $pattern })
    if ($residue.Count -gt 0) {
        throw "Unresolved environment manifest transaction requires manual recovery: $($residue.FullName -join ' | ')"
    }
}

function ConvertTo-NormalizedCondaManifestText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
    return ($Text.Replace("`r`n", "`n").Replace("`r", "`n"))
}

function Get-CondaEnvironmentManifestState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Resolve-SafeLiteralWindowsPath -Value $Path `
        -Name 'Environment manifest path' -RequireExistingParent
    $lock = Enter-CondaManifestMutex $full
    try {
        Assert-NoCondaManifestTransactionResidue $full
        $state = Get-StablePathState $full
        $content = $null
        if ($state.Kind -ceq 'File') {
            $bytes = [IO.File]::ReadAllBytes($full)
            if ((ConvertTo-Sha256Hex $bytes) -cne $state.Fingerprint) {
                throw "Environment manifest changed while it was being read: $full"
            }
            $content = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
            if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
                $content = $content.Substring(1)
            }
        }
        return [PSCustomObject]@{
            Path = $state.Path
            Kind = $state.Kind
            Fingerprint = $state.Fingerprint
            Content = $content
        }
    }
    finally { Exit-CondaManifestMutex $lock }
}

function Write-CondaEnvironmentManifestAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Yaml,
        [Parameter(Mandatory = $true)]$ExpectedState,
        [ValidateSet('Replace', 'KeepExisting', 'SaveGenerated')]
        [string]$Action = 'Replace'
    )

    $Action = switch ($Action.ToLowerInvariant()) {
        'keepexisting' { 'KeepExisting' }
        'savegenerated' { 'SaveGenerated' }
        default { 'Replace' }
    }
    $full = Resolve-SafeLiteralWindowsPath -Value $Path `
        -Name 'Environment manifest path' -RequireExistingParent
    if (-not ([IO.Path]::GetFullPath([string]$ExpectedState.Path)).Equals(
        $full, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Expected environment manifest state belongs to another path.'
    }
    if ([string]$ExpectedState.Kind -notin @('Absent', 'File')) {
        throw "Refusing environment manifest path type '$($ExpectedState.Kind)': $full"
    }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Environment manifest parent directory does not exist: $parent"
    }
    Assert-NoReparseInExistingPath $full 'Environment manifest path'
    $canonicalYaml = ConvertTo-NormalizedCondaManifestText $Yaml
    if ([string]::IsNullOrWhiteSpace($canonicalYaml)) {
        throw 'Environment manifest YAML cannot be empty.'
    }
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $desiredBytes = $utf8.GetBytes($canonicalYaml)
    $desiredFingerprint = ConvertTo-Sha256Hex $desiredBytes
    $leaf = Split-Path -Leaf $full
    $stage = $null
    $replacementBackup = $null
    $lock = Enter-CondaManifestMutex $full
    try {
        Assert-NoCondaManifestTransactionResidue $full
        # The caller may have observed the path before another process replaced
        # an ancestor with a junction while this writer waited for the mutex.
        Assert-NoReparseInExistingPath $full 'Environment manifest path under lock'
        $current = Get-StablePathState $full
        $matchesExpected = [string]$current.Kind -ceq [string]$ExpectedState.Kind
        if ($matchesExpected -and $current.Kind -ceq 'File') {
            $matchesExpected = [string]$current.Fingerprint -ceq [string]$ExpectedState.Fingerprint
        }
        if (-not $matchesExpected) {
            if ($current.Kind -ceq 'File' -and $current.Fingerprint -ceq $desiredFingerprint) {
                return [PSCustomObject]@{
                    Path = $full; Action = 'Equivalent'; Changed = $false
                    Fingerprint = $desiredFingerprint; BackupPath = $null
                }
            }
            throw "Environment manifest changed after observation; compare and confirm again: $full"
        }
        if ($current.Kind -ceq 'File') {
            $currentBytes = [IO.File]::ReadAllBytes($full)
            if ((ConvertTo-Sha256Hex $currentBytes) -cne [string]$current.Fingerprint) {
                throw "Environment manifest changed during its locked read; compare and confirm again: $full"
            }
            $currentText = $utf8.GetString($currentBytes)
            if ((ConvertTo-NormalizedCondaManifestText $currentText) -ceq $canonicalYaml) {
                return [PSCustomObject]@{
                    Path = $full; Action = 'Equivalent'; Changed = $false
                    Fingerprint = $current.Fingerprint; BackupPath = $null
                }
            }
        }
        if ($Action -ceq 'KeepExisting') {
            return [PSCustomObject]@{
                Path = $full; Action = $Action; Changed = $false
                Fingerprint = $current.Fingerprint; BackupPath = $null
            }
        }

        $stage = Join-Path $parent (".$leaf.manifest-stage-$([guid]::NewGuid().ToString('N'))")
        $stream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($desiredBytes, 0, $desiredBytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $null = Assert-StablePathState $stage 'File' $desiredFingerprint `
            'Staged environment manifest'

        if ($Action -ceq 'SaveGenerated') {
            Assert-NoReparseInExistingPath $full 'Generated environment manifest path before commit'
            $extension = [IO.Path]::GetExtension($full)
            $stem = [IO.Path]::GetFileNameWithoutExtension($full)
            $generated = Join-Path $parent ("$stem.generated$extension")
            if (Test-Path -LiteralPath $generated) {
                $generated = Join-Path $parent ("$stem.generated-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N'))$extension")
            }
            [IO.File]::Move($stage, $generated)
            $stage = $null
            $null = Assert-StablePathState $generated 'File' $desiredFingerprint `
                'Saved generated environment manifest'
            return [PSCustomObject]@{
                Path = $generated; Action = $Action; Changed = $true
                Fingerprint = $desiredFingerprint; BackupPath = $null
            }
        }

        $backupPath = $null
        Assert-NoReparseInExistingPath $full 'Environment manifest path before commit'
        if ($current.Kind -ceq 'Absent') {
            [IO.File]::Move($stage, $full)
            $stage = $null
        }
        else {
            Assert-NoReparseInExistingPath $full 'Environment manifest replacement path'
            $replacementBackup = Join-Path $parent `
                (".$leaf.manifest-replace-backup-$([guid]::NewGuid().ToString('N'))")
            if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                $env:MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_AT_REPLACE -eq '1') {
                [IO.File]::WriteAllText($full, "channels:`n  - external`n", $utf8)
            }
            [IO.File]::Replace($stage, $full, $replacementBackup, $true)
            $stage = $null
            $displaced = Get-StablePathState $replacementBackup
            if ($displaced.Kind -cne 'File' -or
                $displaced.Fingerprint -cne [string]$current.Fingerprint) {
                $committed = Get-StablePathState $full
                if ($displaced.Kind -ceq 'File' -and $committed.Kind -ceq 'File' -and
                    $committed.Fingerprint -ceq $desiredFingerprint) {
                    $ourCopy = Join-Path $parent `
                        (".$leaf.manifest-stage-$([guid]::NewGuid().ToString('N'))")
                    if ((Test-MinicondaPythonEnvFaultInjectionEnabled) -and
                        $env:MINICONDA_PYTHON_ENV_MANIFEST_TEST_EXTERNAL_WRITE_BEFORE_RESTORE -eq '1') {
                        [IO.File]::WriteAllText($full,
                            "channels:`n  - second-external`n", $utf8)
                    }
                    [IO.File]::Replace($replacementBackup, $full, $ourCopy, $true)
                    $replacementBackup = $null
                    try {
                        $null = Assert-StablePathState $full 'File' $displaced.Fingerprint `
                            'Restored concurrent environment manifest'
                        $null = Assert-StablePathState $ourCopy 'File' $desiredFingerprint `
                            'Displaced skill environment manifest'
                    }
                    catch {
                        throw "Environment manifest changed during final restoration; preserved evidence: $full | $ourCopy | $($_.Exception.Message)"
                    }
                    Remove-Item -LiteralPath $ourCopy -Force -ErrorAction Stop
                    throw "Environment manifest changed in the final replacement window; external bytes were restored: $full"
                }
                throw "Environment manifest changed in the final replacement window; preserved both copies: $full | $replacementBackup"
            }
            $null = Assert-StablePathState $full 'File' $desiredFingerprint `
                'Committed environment manifest'
            $extension = [IO.Path]::GetExtension($full)
            $stem = [IO.Path]::GetFileNameWithoutExtension($full)
            $backupPath = Join-Path $parent ("$stem.backup-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N'))$extension")
            [IO.File]::Move($replacementBackup, $backupPath)
            $replacementBackup = $null
        }
        $null = Assert-StablePathState $full 'File' $desiredFingerprint `
            'Saved environment manifest'
        return [PSCustomObject]@{
            Path = $full; Action = $Action; Changed = $true
            Fingerprint = $desiredFingerprint; BackupPath = $backupPath
        }
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        }
        Exit-CondaManifestMutex $lock
    }
}

function Invoke-CondaEnvironmentYamlExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('isolated-conda-forge', 'project-isolated', 'project-inherited', 'preserve')]
        [string]$ChannelPolicy,
        [string]$ManifestPath,
        $ApprovedPreview
    )

    $ChannelPolicy = $ChannelPolicy.ToLowerInvariant()
    $condaFull = [IO.Path]::GetFullPath($CondaExe)
    $envFull = [IO.Path]::GetFullPath($EnvPath)
    $isProjectPolicy = $ChannelPolicy -in @('project-isolated', 'project-inherited')
    if ($isProjectPolicy -and [string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw "Channel policy '$ChannelPolicy' requires the project manifest path."
    }
    if ($ChannelPolicy -ceq 'project-inherited' -and -not $ApprovedPreview) {
        throw 'Inherited PROJECT export requires the exact preview the user approved.'
    }
    $context = $null
    $originalError = $null
    try {
        if ($isProjectPolicy) {
            $useInherited = $ChannelPolicy -ceq 'project-inherited'
            $context = New-CondaProjectExecutionContext -ManifestPath $ManifestPath `
                -UseInheritedConfiguration:$useInherited
            if ($ApprovedPreview) {
                if (-not ([IO.Path]::GetFullPath([string]$ApprovedPreview.ManifestPath)).Equals(
                        $context.ManifestPath, [StringComparison]::OrdinalIgnoreCase) -or
                    -not ([IO.Path]::GetFullPath([string]$ApprovedPreview.EnvPath)).Equals(
                        $envFull, [StringComparison]::OrdinalIgnoreCase) -or
                    -not ([IO.Path]::GetFullPath([string]$ApprovedPreview.CondaExe)).Equals(
                        $condaFull, [StringComparison]::OrdinalIgnoreCase) -or
                    [bool]$ApprovedPreview.UseInheritedConfiguration -ne $useInherited -or
                    [string]$ApprovedPreview.ManifestFingerprint -cne $context.ManifestFingerprint) {
                    throw 'Export policy no longer matches the approved PROJECT preview.'
                }
                $approvedPlanView = [PSCustomObject]@{
                    Fingerprint = [string]$ApprovedPreview.PlanFingerprint
                    ChannelConfigurationFingerprint = [string]$ApprovedPreview.ChannelConfigurationFingerprint
                    ResolvedSources = @($ApprovedPreview.ResolvedSources)
                    PlannedChannels = @($ApprovedPreview.PlannedChannels)
                    VariableNames = @($ApprovedPreview.VariableNames)
                    PythonVersion = [string]$ApprovedPreview.PythonVersion
                    PythonMajorMinor = [string]$ApprovedPreview.PythonMajorMinor
                    PackageCount = [int]$ApprovedPreview.PackageCount
                }
                $recordFingerprint = Get-CondaProjectApprovalFingerprint `
                    -ManifestPath $context.ManifestPath -EnvPath $envFull -CondaExe $condaFull `
                    -UseInheritedConfiguration $useInherited `
                    -ManifestFingerprint $context.ManifestFingerprint -Plan $approvedPlanView
                if ($recordFingerprint -cne [string]$ApprovedPreview.ApprovalFingerprint) {
                    throw 'Approved PROJECT export record is incomplete or changed; preview and confirmation must be repeated.'
                }
            }
        }
        else {
            $context = [PSCustomObject]@{ CondarcPath = $null }
        }

        $approvedIdentifiers = @()
        $approvedSources = @()
        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('env', 'export', '--prefix', $envFull, '--no-builds')) {
            $arguments.Add($argument)
        }
        if ($ChannelPolicy -ceq 'isolated-conda-forge') {
            $approvedIdentifiers = @('https://conda.anaconda.org/conda-forge')
            $approvedSources = $approvedIdentifiers
            foreach ($argument in @('-c', $approvedIdentifiers[0], '--override-channels')) { $arguments.Add($argument) }
        }
        elseif ($ChannelPolicy -ceq 'project-isolated') {
            $approvedIdentifiers = @(Get-IsolatableProjectManifestChannels $context.ManifestPath | Where-Object { $_ -cne 'nodefaults' })
            foreach ($channel in $approvedIdentifiers) {
                $arguments.Add('-c')
                $arguments.Add([string]$channel)
            }
            $arguments.Add('--override-channels')
        }
        elseif ($ChannelPolicy -ceq 'project-inherited') {
            $approvedIdentifiers = @($ApprovedPreview.PlannedChannels | Where-Object { $_ -cne 'nodefaults' })
            if ($approvedIdentifiers.Count -eq 0) { $approvedIdentifiers = @($ApprovedPreview.ResolvedSources) }
            $approvedSources = @($ApprovedPreview.ResolvedSources)
        }
        if ($ChannelPolicy -ne 'preserve') {
            $configJson = Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                -ArgumentList @('config', '--show', 'channel_alias', 'default_channels', 'custom_channels', 'custom_multichannels', 'channels', '--json') `
                -Label 'conda export channel policy'
            try { $configuration = $configJson | ConvertFrom-Json }
            catch { throw "Conda export channel policy was not valid JSON: $($_.Exception.Message)" }
            $configurationCanonical = $configuration | ConvertTo-Json -Depth 100 -Compress
            if ($ApprovedPreview) {
                $configurationFingerprint = ConvertTo-Sha256Hex ([Text.Encoding]::UTF8.GetBytes($configurationCanonical))
                if ($configurationFingerprint -cne [string]$ApprovedPreview.ChannelConfigurationFingerprint) {
                    throw 'Conda channel configuration changed after PROJECT approval; preview and confirmation must be repeated.'
                }
            }
            if ($approvedSources.Count -eq 0) {
                foreach ($identifier in $approvedIdentifiers) {
                    $approvedSources += @(Resolve-CondaPlannedChannel -Identifier $identifier -Configuration $configuration)
                }
            }
            $installedJson = Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                -ArgumentList @('list', '--prefix', $envFull, '--json') -Label 'conda installed-channel audit'
            $installedSources = @(Get-CondaInstalledChannelSources -Json $installedJson -Configuration $configuration)
            foreach ($source in $installedSources) {
                if (-not ($approvedSources | Where-Object { $_.TrimEnd('/').Equals(
                                $source.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase) })) {
                    throw "Installed package channel '$source' is outside the approved export policy."
                }
            }
        }
        $raw = Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
            -ArgumentList @($arguments) -Label 'conda environment YAML export'
        if ($ChannelPolicy -ne 'preserve') {
            $configAfterJson = Invoke-CondaProjectChild -CondaExe $condaFull -Context $context `
                -ArgumentList @('config', '--show', 'channel_alias', 'default_channels', 'custom_channels', 'custom_multichannels', 'channels', '--json') `
                -Label 'conda export channel policy (after)'
            try { $configAfterCanonical = ($configAfterJson | ConvertFrom-Json) | ConvertTo-Json -Depth 100 -Compress }
            catch { throw "Post-export conda channel policy was not valid JSON: $($_.Exception.Message)" }
            if ($configAfterCanonical -cne $configurationCanonical) {
                throw 'Conda channel configuration changed during export; discard the output and retry.'
            }
        }
        if ($raw -match '(?m)^variables:\s*(?:#.*)?$') {
            throw 'Conda export contains environment variables; review and redact them manually instead of writing their values automatically.'
        }
        if ($raw -match '(?im)^\s*-\s+(?:pip|[''"]pip[''"]):\s*(?:#.*)?$') {
            throw 'Conda export contains a pip subsection whose package sources are not bound by this restore policy; export a separate reviewed requirements/lock file instead.'
        }
        $filteredText = Remove-CondaYamlMachineMetadata $raw
        $filtered = @($filteredText -split '\r?\n')
        if ($filteredText -match '(?im)(?:https?://[^\s/]+@|/t/[^/\s]+|^\s+-\s+(?:-e|--editable)\s+|\s@\s*(?:https?|git\+|file):|file:///|(?<![A-Za-z])[A-Za-z]:[\\/]|\\\\)') {
            throw 'Conda export contains credentials, token paths, editable/direct URLs, or machine-local dependency paths; refusing an unsafe restore manifest.'
        }
        if (-not ($filtered | Where-Object { $_ -match '^dependencies:\s*' })) {
            throw 'Conda export did not produce a recognizable environment YAML document.'
        }
        $yaml = ($filtered -join "`n").TrimEnd() + "`n"
        if ($ChannelPolicy -ne 'preserve') {
            $yaml = Set-CondaYamlChannelPolicy -Yaml $yaml -Channel $approvedIdentifiers
        }
        if ($yaml -match '(?im)(?:https?://[^\s/]+@|/t/[^/\s]+|file:///|(?<![A-Za-z])[A-Za-z]:[\\/]|\\\\)') {
            throw 'Final conda restore manifest contains credentials, token paths, or machine-local paths.'
        }
        return $yaml
    }
    catch { $originalError = $_ }
    finally {
        if ($isProjectPolicy -and $context) {
            try { Close-CondaProjectExecutionContext $context }
            catch {
                if ($originalError) {
                    throw "Conda export and policy cleanup both failed. Original: $($originalError.Exception.Message) Cleanup: $($_.Exception.Message)"
                }
                throw
            }
        }
    }
    throw $originalError
}

function Resolve-ValidatedCondaExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Candidate)

    $sawCandidate = $false
    foreach ($rawCandidate in $Candidate | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $rawCandidate -PathType Leaf)) { continue }
        $sawCandidate = $true
        $candidateFull = [IO.Path]::GetFullPath($rawCandidate)
        try {
            $probe = Invoke-NativeCaptured { & $candidateFull info --json } "conda identity probe ($candidateFull)"
            if ($probe.ExitCode -ne 0) {
                throw "info --json exited $($probe.ExitCode): $($probe.StdErr.Trim())"
            }
            $info = $probe.StdOut | ConvertFrom-Json
            if ([string]::IsNullOrWhiteSpace([string]$info.conda_version) -or
                [string]::IsNullOrWhiteSpace([string]$info.root_prefix) -or
                -not [IO.Path]::IsPathRooted([string]$info.root_prefix) -or
                -not (Test-Path -LiteralPath ([string]$info.root_prefix) -PathType Container)) {
                throw 'info --json lacked a usable conda_version/root_prefix identity.'
            }
            return $candidateFull
        }
        catch { throw "Conda candidate exists but failed identity validation; refusing fallback past '$candidateFull': $($_.Exception.Message)" }
    }
    if (-not $sawCandidate) { throw 'No conda candidate path exists.' }
    throw 'No candidate proved it was a usable conda executable.'
}

function Assert-ExactPythonInterpreter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [string]$ExpectedMajorMinor
    )

    $pythonExe = [IO.Path]::GetFullPath($PythonExe)
    $envFull = Split-Path -Parent $pythonExe
    Assert-NoReparseInExistingPath $envFull 'Python environment'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        throw "Python interpreter is missing: $pythonExe"
    }
    $pythonItem = Get-Item -LiteralPath $pythonExe -Force -ErrorAction Stop
    if (($pythonItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Python interpreter is a reparse point: $pythonExe"
    }
    $probe = Invoke-NativeChecked {
        # Avoid embedded double quotes: Windows PowerShell 5.1 can strip them
        # while rebuilding a native command line for python.exe.
        & $pythonExe -c 'import sys; print(sys.executable); print(str(sys.version_info.major)+''.''+str(sys.version_info.minor))'
    } 'exact Python interpreter health check'
    Assert-NoReparseInExistingPath $envFull 'Python environment after health check'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        throw "Python interpreter disappeared during its health check: $pythonExe"
    }
    $pythonItemAfter = Get-Item -LiteralPath $pythonExe -Force -ErrorAction Stop
    if (($pythonItemAfter.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Python interpreter became a reparse point during its health check: $pythonExe"
    }
    $probeLines = @($probe -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($probeLines.Count -ne 2 -or
        -not ([IO.Path]::GetFullPath($probeLines[0].Trim())).Equals(
            [IO.Path]::GetFullPath($pythonExe), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Python health output did not identify the exact interpreter: $pythonExe"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMajorMinor) -and
        $probeLines[1].Trim() -cne $ExpectedMajorMinor) {
        throw "Python did not report approved version ${ExpectedMajorMinor}: $pythonExe"
    }
    return $pythonExe
}

function Assert-CondaEnvironmentPython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [string]$ExpectedMajorMinor
    )

    $pythonExe = Join-Path ([IO.Path]::GetFullPath($EnvPath)) 'python.exe'
    return Assert-ExactPythonInterpreter -PythonExe $pythonExe `
        -ExpectedMajorMinor $ExpectedMajorMinor
}

function Get-ExistingPythonEnvironmentIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$EnvPath)

    $envFull = [IO.Path]::GetFullPath($EnvPath).TrimEnd('\')
    Assert-NoReparseInExistingPath $envFull 'existing Python environment'
    if (-not (Test-Path -LiteralPath $envFull -PathType Container)) {
        throw "Existing Python environment directory is missing: $envFull"
    }
    $hasConda = Test-Path -LiteralPath (Join-Path $envFull 'conda-meta\history') -PathType Leaf
    $hasVenv = Test-Path -LiteralPath (Join-Path $envFull 'pyvenv.cfg') -PathType Leaf
    if ($hasConda -eq $hasVenv) {
        throw "Existing environment has ambiguous or missing conda/venv identity markers: $envFull"
    }
    $pythonExe = if ($hasConda) {
        Join-Path $envFull 'python.exe'
    }
    else {
        Join-Path $envFull 'Scripts\python.exe'
    }
    $pythonExe = Assert-ExactPythonInterpreter -PythonExe $pythonExe
    return [PSCustomObject]@{
        Kind = if ($hasConda) { 'conda' } else { 'venv' }
        EnvPath = $envFull
        PythonExe = $pythonExe
    }
}

function Remove-OwnedManagedCondaEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('TEMP', 'STANDALONE', 'PROJECT')][string]$Lifecycle,
        [Parameter(Mandatory = $true)][string]$ManagedRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)]$Claim
    )

    $envFull = [IO.Path]::GetFullPath($EnvPath)
    if ($envFull -notmatch '^[A-Za-z]:\\$') { $envFull = $envFull.TrimEnd('\') }
    Assert-ManagedEnvironmentCreationPath -Lifecycle $Lifecycle `
        -ManagedRoot $ManagedRoot -EnvPath $envFull
    $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
    if (-not (Test-Path -LiteralPath $envFull)) {
        Remove-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
        return
    }

    $condaHistory = Join-Path $envFull 'conda-meta\history'
    if (Test-Path -LiteralPath $condaHistory -PathType Leaf) {
        $markerPath = [IO.Path]::GetFullPath([string]$Claim.MarkerPath)
        $markerBytes = [IO.File]::ReadAllBytes($markerPath)
        $removeError = $null
        try {
            $null = Invoke-WithIsolatedCondaExecutionContext `
                -Label 'Conda environment removal policy' -Operation {
                    param($context)
                    Invoke-CondaProjectChild -CondaExe $CondaExe -Context $context `
                        -ArgumentList @('remove', '--prefix', $envFull, '--all', '-y', '-c',
                            'https://conda.anaconda.org/conda-forge', '--override-channels', '--offline') `
                        -Label 'conda env removal'
                }
        }
        catch { $removeError = $_ }
        if ((Test-Path -LiteralPath $envFull -PathType Container) -and
            -not (Test-Path -LiteralPath $markerPath)) {
            try {
                $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle `
                    -EnvPath $envFull -AllowMissingMarkerIfEnvironmentExists
                $restoreStream = [IO.File]::Open($markerPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $restoreStream.Write($markerBytes, 0, $markerBytes.Length)
                    $restoreStream.Flush($true)
                }
                finally { $restoreStream.Dispose() }
                $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
            }
            catch {
                if ($removeError) {
                    throw "Conda removal and marker rollback both failed. Original: $($removeError.Exception.Message) Rollback: $($_.Exception.Message)"
                }
                throw
            }
        }
        if ($removeError) { throw $removeError }
    }
    if (Test-Path -LiteralPath $envFull) {
        $null = Assert-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
        Remove-OwnedEnvironmentDirectoryKeepingMarkerLast -Claim $Claim `
            -Lifecycle $Lifecycle -EnvPath $envFull
    }
    Remove-ManagedEnvironmentClaim -Claim $Claim -Lifecycle $Lifecycle -EnvPath $envFull
}

function Remove-OwnedTempCondaEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TempEnvRoot,
        [Parameter(Mandatory = $true)][string]$EnvPath,
        [Parameter(Mandatory = $true)][string]$EnvName,
        [Parameter(Mandatory = $true)][string]$CondaExe,
        [Parameter(Mandatory = $true)]$Claim
    )

    $envFull = [IO.Path]::GetFullPath($EnvPath)
    if ((Split-Path -Leaf $envFull) -cne $EnvName) {
        throw "Refusing cleanup for a TEMP name/path mismatch: $EnvName | $envFull"
    }
    Remove-OwnedManagedCondaEnv -Lifecycle TEMP -ManagedRoot $TempEnvRoot `
        -EnvPath $envFull -CondaExe $CondaExe -Claim $Claim
}
