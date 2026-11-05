#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Created 2026-11-02: read deployment/installation properties without executing values.
function Read-ReleaseProperties {
    param([string]$Path)
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith('!')) { continue }
        $parts = $line.Split('=', 2)
        if ($parts.Count -ne 2 -or $values.ContainsKey($parts[0].Trim())) {
            throw 'Invalid or duplicate properties entry.'
        }
        $value = $parts[1].TrimStart()
        if ($value -match '(?<!\\)(\\\\)*\\$') { throw 'Use single-line Java properties; continuations are unsupported.' }
        $values[$parts[0].Trim()] = [regex]::Replace($value, '\\(u[0-9a-fA-F]{4}|.)', {
            param($match)
            $escape = $match.Groups[1].Value
            if ($escape.StartsWith('u') -and $escape.Length -eq 5) {
                return [string][char][Convert]::ToInt32($escape.Substring(1), 16)
            }
            switch -CaseSensitive ($escape) {
                'n' { return "`n" }; 'r' { return "`r" }; 't' { return "`t" }; 'f' { return "`f" }
                default { return $escape }
            }
        })
    }
    return $values
}

# Created 2026-11-02: replace a small runtime identity file atomically within its own directory.
function Write-ReleaseJson {
    param([string]$Path, $Value)
    $pending = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.next'
    [IO.File]::WriteAllText($pending, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($pending, $Path, $true)
}

# Created 2026-11-02: validate every packaged byte before a stop or installation write is possible.
function Read-ReleasePackage {
    param([string]$Directory, [string]$Commit, [switch]$RequireCi)
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'ExpectedCommit must be a full commit SHA.' }
    $root = (Resolve-Path -LiteralPath $Directory).Path
    $releasePath = Join-Path $root 'release.json'
    $release = Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
    if ($release.format -ne 'payse-release-v1' -or $release.javaMajor -ne 21 -or
        $release.commit -cne $Commit -or $release.workflow -ne '.github/workflows/release.yml' -or
        $release.branch -cnotin @('develop', 'sunghyun-dev') -or
        $release.repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $release.runId -lt 0) {
        throw 'Release identity or Java contract differs.'
    }
    foreach ($required in @('server.jar', 'manifest.json', 'release-schema.json')) {
        if (-not $release.sha256.PSObject.Properties[$required]) { throw 'Required release file missing.' }
    }
    foreach ($entry in $release.sha256.PSObject.Properties) {
        if ($entry.Name -notmatch '^[A-Za-z0-9_.-]+$' -or $entry.Name -in @('.', '..') -or
            $entry.Value -cnotmatch '^[0-9a-f]{64}$') { throw 'Unsafe release manifest entry.' }
        $file = Get-Item -LiteralPath (Join-Path $root $entry.Name)
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.PSIsContainer -or
            (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant() -cne $entry.Value) {
            throw 'Release integrity check failed.'
        }
    }
    $permitted = @($release.sha256.PSObject.Properties.Name) + @('release.json', 'ci-receipt.json')
    foreach ($file in Get-ChildItem -LiteralPath $root -Force) {
        if ($file.Name -cnotin $permitted -or $file.PSIsContainer -or
            $file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected release contents.' }
    }
    $jar = Join-Path $root 'server.jar'
    $zip = [IO.Compression.ZipFile]::OpenRead($jar)
    try {
        $entry = $zip.GetEntry('META-INF/MANIFEST.MF')
        if ($null -eq $entry) { throw 'JAR manifest missing.' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($manifest -notmatch '(?m)^Start-Class: com\.payse\.api\.PayseApiApplication\r?$' -or
            $manifest -notmatch '(?m)^Main-Class: org\.springframework\.boot\.loader\.launch\.JarLauncher\r?$' -or
            $manifest -notmatch '(?m)^Build-Jdk-Spec: 21\r?$' -or
            $null -eq $zip.GetEntry('BOOT-INF/classes/com/payse/api/PayseApiApplication.class')) {
            throw 'Not a PAYSE Java 21 executable JAR.'
        }
    } finally { $zip.Dispose() }
    if ($RequireCi) {
        $receipt = Get-Content -LiteralPath (Join-Path $root 'ci-receipt.json') -Raw | ConvertFrom-Json
        if ($receipt.format -ne 'payse-ci-receipt-v1' -or $release.runId -le 0 -or
            $receipt.commit -cne $Commit -or $receipt.runId -ne $release.runId -or
            $receipt.repository -cne $release.repository -or $receipt.branch -cne $release.branch -or
            $receipt.workflow -ne $release.workflow -or
            $receipt.releaseSha256 -cne (Get-FileHash -LiteralPath $releasePath).Hash.ToLowerInvariant()) {
            throw 'Successful CI download receipt is missing or differs. Fetch the release first.'
        }
    }
    return [pscustomobject]@{ root = $root; jar = $jar; release = $release }
}

# Created 2026-11-02; modified 2026-11-04: AI requires the portable installation with status and preparation support.
function Test-ReleaseProfiles {
    param($Properties, $Schema)
    if ($Schema.format -ne 'payse-schema-prerequisites-v1') { throw 'Unsupported schema prerequisites.' }
    $profiles = @($Properties['spring.profiles.active'].Split(',') | ForEach-Object { $_.Trim() })
    if (@($profiles | Where-Object { $_ -notin $Schema.supportedProfiles }).Count -or
        @($Schema.requiredProfiles | Where-Object { $_ -notin $profiles }).Count) {
        throw 'Profile compatibility is not established. No automatic profile or DB migration is allowed.'
    }
    if ('analysis' -in $profiles -or 'gamma-local' -in $profiles) {
        throw 'AI profiles require portable_server.py; the legacy adapter does not prepare or monitor AI.'
    }
    return $profiles
}

# Created 2026-11-02: query catalog metadata in a read-only transaction without logging credentials or business rows.
function Test-ReleaseDatabase {
    param($Plan, $Properties, $Schema)
    $jdbc = $Properties['PAYSE_JDBC_URL']
    if (-not $jdbc.StartsWith('jdbc:postgresql://')) { throw 'Unsupported installed JDBC URL.' }
    $uri = [Uri]$jdbc.Substring(5)
    $database = $uri.AbsolutePath.TrimStart('/')
    if ($uri.Host -ne '127.0.0.1' -or $uri.Port -ne $Plan.settings.databasePort -or
        $uri.Query -or $uri.UserInfo -or $database -notmatch '^[A-Za-z0-9_]+$') {
        throw 'Database connection does not match the owned local installation.'
    }
    $conditions = [Collections.Generic.List[string]]::new()
    $conditions.Add("NOT rolsuper AND NOT rolbypassrls AND pg_has_role(session_user, 'payse_runtime', 'member')")
    foreach ($table in $Schema.tables) {
        if ($table -notmatch '^[a-z_]+$') { throw 'Invalid schema table.' }
        $conditions.Add("to_regclass('payse.$table') IS NOT NULL")
    }
    foreach ($column in $Schema.columns) {
        if ($column -notmatch '^([a-z_]+)\.([a-z_]+)$') { throw 'Invalid schema column.' }
        $table, $name = $Matches[1], $Matches[2]
        $conditions.Add("EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid=to_regclass('payse.$table') AND attname='$name' AND NOT attisdropped)")
    }
    foreach ($function in $Schema.functions) {
        if ($function -notmatch '^[a-z_]+$') { throw 'Invalid schema function.' }
        $conditions.Add("EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='payse' AND p.proname='$function')")
    }
    $sql = "BEGIN READ ONLY; SET LOCAL ROLE payse_runtime; SELECT CASE WHEN (" + ($conditions -join ') AND (') + ") THEN 'READY' ELSE 'INCOMPATIBLE' END FROM pg_roles WHERE rolname=session_user; ROLLBACK;"
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $Plan.settings.postgresBin 'psql.exe'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($key in @($info.Environment.Keys)) {
        if ($key -match '^PG') { [void]$info.Environment.Remove($key) }
    }
    $info.Environment['PGPASSWORD'] = [IO.File]::ReadAllText((Join-Path $Plan.root 'secrets/PAYSE_DB_PASSWORD'))
    $info.Environment['PGOPTIONS'] = '-c default_transaction_read_only=on -c statement_timeout=5000 -c lock_timeout=1000'
    $info.Environment['PGCONNECT_TIMEOUT'] = '5'
    foreach ($arg in @('-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1',
            '-p', [string]$uri.Port, '-U', $Properties['PAYSE_DB_USER'], '-d', $database, '-c', $sql)) {
        $info.ArgumentList.Add($arg)
    }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(12000)) { $process.Kill(); throw 'Read-only schema check timed out.' }
        if ($process.ExitCode -ne 0 -or $stdout.Result.Trim() -ne 'READY') {
            throw 'Installed database prerequisites or runtime privileges are incompatible.'
        }
    } finally {
        [void]$info.Environment.Remove('PGPASSWORD')
        $process.Dispose()
    }
}

# Created 2026-11-05: use the installation's public plan and verify the caller's exact API identity.
function Get-ReleaseApiTarget {
    param([string]$Config, $Identity)
    if ($null -eq $Identity) { throw 'API process identity is missing.' }
    $fresh = Get-PayseStopPlan -Config $Config
    $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$Identity.pid)
    if ($null -eq $fresh.api -and $null -eq $current) { return $null }
    if ($null -eq $fresh.api -or $fresh.api.identity.pid -ne $Identity.pid -or
        -not (Test-PayseStopIdentity $current $Identity)) {
        throw 'API identity changed after preflight; no signal was sent.'
    }
    return $fresh.api
}

# Created 2026-11-02: apply under caller-held locks; restore old bytes and a new old-release process on startup failure.
function Invoke-ReleaseTransaction {
    param([string]$JarPath, [string]$RuntimePath, [string]$CandidatePath, [string]$Commit,
        [string]$BackupDirectory, [string]$ExpectedOldHash, [string]$ExpectedNewHash,
        [scriptblock]$StopApi, [scriptblock]$StartApi, [scriptblock]$WaitHealthy)
    if ((Get-FileHash -LiteralPath $JarPath).Hash -ine $ExpectedOldHash -or
        (Get-FileHash -LiteralPath $CandidatePath).Hash -ine $ExpectedNewHash) { throw 'JAR changed after preflight.' }
    if (Test-Path -LiteralPath $BackupDirectory) { throw 'Backup directory already exists.' }
    [void][IO.Directory]::CreateDirectory($BackupDirectory)
    $oldRuntimeBytes = [IO.File]::ReadAllBytes($RuntimePath)
    $oldRuntime = [Text.Encoding]::UTF8.GetString($oldRuntimeBytes) | ConvertFrom-Json
    [IO.File]::Copy($JarPath, (Join-Path $BackupDirectory 'server.jar'), $false)
    [IO.File]::WriteAllBytes((Join-Path $BackupDirectory 'runtime.json'), $oldRuntimeBytes)
    $stopped = $false
    try {
        & $StopApi $oldRuntime.process
        $stopped = $true
        $pending = $JarPath + '.' + [Guid]::NewGuid().ToString('N') + '.next'
        [IO.File]::Copy($CandidatePath, $pending, $false)
        if ((Get-FileHash -LiteralPath $pending).Hash -ine $ExpectedNewHash) { throw 'Staged JAR hash differs.' }
        [IO.File]::Move($pending, $JarPath, $true)
        $current = [Text.Encoding]::UTF8.GetString($oldRuntimeBytes) | ConvertFrom-Json
        $current.jarSha256 = $ExpectedNewHash.ToLowerInvariant()
        $current | Add-Member -NotePropertyName sourceCommit -NotePropertyValue $Commit -Force
        Write-ReleaseJson $RuntimePath $current
        $identity = & $StartApi $current
        $current.process = $identity
        Write-ReleaseJson $RuntimePath $current
        & $WaitHealthy $identity
        return [pscustomobject]@{ status = 'DEPLOYED'; commit = $Commit; backup = $BackupDirectory }
    } catch {
        if (-not $stopped) { throw 'API shutdown did not complete; installed files were preserved.' }
        try {
            $failed = Get-Content -LiteralPath $RuntimePath -Raw | ConvertFrom-Json
            & $StopApi $failed.process
            $restore = $JarPath + '.' + [Guid]::NewGuid().ToString('N') + '.restore'
            [IO.File]::Copy((Join-Path $BackupDirectory 'server.jar'), $restore, $false)
            [IO.File]::Move($restore, $JarPath, $true)
            Write-ReleaseJson $RuntimePath $oldRuntime
            $oldRuntime.process = & $StartApi $oldRuntime
            Write-ReleaseJson $RuntimePath $oldRuntime
            & $WaitHealthy $oldRuntime.process
        } catch {
            throw 'Deployment and automatic recovery did not complete. Preserve backups; inspect deployment-result.json and process identities. No force-kill was used.'
        }
        throw 'Deployment failed; the previous JAR was restored and is healthy.'
    }
}

Export-ModuleMember -Function Read-ReleaseProperties, Write-ReleaseJson, Read-ReleasePackage,
    Test-ReleaseProfiles, Test-ReleaseDatabase, Get-ReleaseApiTarget, Invoke-ReleaseTransaction
