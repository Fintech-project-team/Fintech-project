#Requires -Version 7.2
param(
    [Parameter(Mandatory=$true)][string]$Properties,
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$ExpectedCommit,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Release-Control.psm1') -Force
$locks = $null
$deploymentLock = $null
$resultPath = $null
$result = [ordered]@{ status = 'CHECKING'; checkedAt = [DateTimeOffset]::Now.ToString('o'); applied = $false }
try {
    if (-not $IsWindows) { throw 'This adapter is for an existing Windows launch.json installation. Use portable_server.py for new PCs.' }
    $options = Read-ReleaseProperties (Resolve-Path -LiteralPath $Properties).Path
    foreach ($key in @('deployment.installRoot', 'deployment.maxHeapMiB', 'deployment.minFreeGiB')) {
        if (-not $options[$key]) { throw ('Configure ' + $key + ' in the private properties file.') }
    }
    $heap = [int]$options['deployment.maxHeapMiB']
    $minimum = [int]$options['deployment.minFreeGiB']
    if ($heap -lt 512 -or $heap -gt 4096 -or $minimum -lt 4 -or $minimum -gt 32 -or
        $minimum -lt ($heap / 1024 + 2)) {
        throw 'Heap must be 512..4096 MiB and free memory threshold 4..32 GiB.'
    }
    $root = (Resolve-Path -LiteralPath $options['deployment.installRoot']).Path
    $candidate = Read-ReleasePackage -Directory $Package -Commit $ExpectedCommit -RequireCi:$Apply
    $configPath = Join-Path $root 'launch.json'
    $settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ($settings.jarFile -ne 'server.jar' -or $settings.propertiesFile -ne 'server.properties' -or
        $settings.runtimeFile -ne 'runtime.json') { throw 'Unsupported installation layout; no files changed.' }
    $jarPath = Join-Path $root 'server.jar'
    $runtimePath = Join-Path $root 'runtime.json'
    $runtime = Get-Content -LiteralPath $runtimePath -Raw | ConvertFrom-Json
    $oldHash = (Get-FileHash -LiteralPath $jarPath).Hash
    $propertiesPath = Join-Path $root 'server.properties'
    if ($oldHash -ine $runtime.jarSha256 -or
        (Get-FileHash -LiteralPath $propertiesPath).Hash -ine $runtime.configSha256) {
        throw 'Installed JAR/config differs from its recorded identity.'
    }
    $javaVersion = (& $settings.javaPath -version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $javaVersion -notmatch 'version "21[."]') { throw 'Java 21 is required.' }
    Import-Module (Join-Path $root 'Stop-Control.psm1') -Force
    $plan = Get-PayseStopPlan -Config $configPath
    if ($null -eq $plan.api -or $null -eq $plan.database -or $null -eq $plan.https) {
        throw 'Start the existing installation normally before a manual release.'
    }
    $installedProperties = Read-ReleaseProperties $propertiesPath
    $schema = Get-Content -LiteralPath (Join-Path $candidate.root 'release-schema.json') -Raw | ConvertFrom-Json
    $profiles = Test-ReleaseProfiles $installedProperties $schema
    Test-ReleaseDatabase $plan $installedProperties $schema
    $memory = Get-CimInstance Win32_OperatingSystem
    if ($memory.FreePhysicalMemory / 1MB -lt $minimum -or $memory.FreeVirtualMemory / 1MB -lt $minimum) {
        throw 'Insufficient memory headroom; no application was stopped.'
    }
    $url = 'http://127.0.0.1:' + $settings.apiPort + '/internal/health/live'
    if ((Invoke-RestMethod -Uri $url -NoProxy -TimeoutSec 3).status -ne 'UP') { throw 'Existing API is not healthy.' }
    Send-PayseStopSignal $plan $plan.api -ProbeOnly
    $result.status = 'COMPATIBLE'
    $result.commit = $candidate.release.commit
    $result.profiles = $profiles
    $result.dbPrerequisites = 'PASS_READ_ONLY_CATALOG'
    $result.freePhysicalGiB = [math]::Round($memory.FreePhysicalMemory / 1MB, 2)
    $result.freeCommitGiB = [math]::Round($memory.FreeVirtualMemory / 1MB, 2)
    if (-not $Apply) {
        $result | ConvertTo-Json -Depth 6
        Write-Host 'CHECK ONLY: server unchanged. Apply requires a successful CI download receipt and an agreed interruption window.'
        exit 0
    }
    $deploymentLock = [IO.File]::Open((Join-Path $root 'logs/manual/deployment.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $resultPath = Join-Path $root 'deployment-result.json'
    Import-Module (Join-Path $root 'Start-Control.psm1') -Force
    # The existing healthy process is reused; this initializes its established detached launcher.
    if ((Invoke-PayseStartWorker -Config $configPath -WaitMilliseconds 45000) -ne 0) {
        throw 'Existing installation preflight failed; no release was applied.'
    }
    $locks = Enter-PayseStopLocks -Root $root
    $plan = Get-PayseStopPlan -Config $configPath
    if ($null -eq $plan.api -or $null -eq $plan.database -or $null -eq $plan.https) {
        throw 'Installation changed before deployment.'
    }
    $candidate = Read-ReleasePackage -Directory $Package -Commit $ExpectedCommit -RequireCi
    if ((Get-FileHash -LiteralPath $propertiesPath).Hash -ine $runtime.configSha256) {
        throw 'Configuration changed before deployment.'
    }
    $memory = Get-CimInstance Win32_OperatingSystem
    if ($memory.FreePhysicalMemory / 1MB -lt $minimum -or $memory.FreeVirtualMemory / 1MB -lt $minimum) {
        throw 'Memory headroom changed; no application was stopped.'
    }
    $before = @{}
    foreach ($path in @($propertiesPath, $configPath, (Join-Path $root 'https/settings.json'))) {
        $before[$path] = (Get-FileHash -LiteralPath $path).Hash
    }
    $stopApi = {
        param($identity)
        $target = Get-ReleaseApiTarget -Config $configPath -Identity $identity
        if ($null -ne $target) {
            Send-PayseStopSignal $plan $target -ProbeOnly
            Send-PayseStopSignal $plan $target
            Wait-PayseStopped $target 60
        }
    }
    $startApi = {
        param($state)
        $saved = @{}
        try {
            foreach ($entry in @(Get-ChildItem Env: | Where-Object Name -match '^(PAYSE_|SPRING_|JAVA_TOOL_OPTIONS$|JDK_JAVA_OPTIONS$|_JAVA_OPTIONS$|LC_ALL$)')) {
                $saved[$entry.Name] = $entry.Value
                [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
            }
            $argv = @('-Xms128m', ('-Xmx' + $heap + 'm'), '-XX:MaxMetaspaceSize=384m',
                '-XX:ReservedCodeCacheSize=128m', '-XX:ActiveProcessorCount=2', '-jar', $jarPath,
                ('--spring.config.additional-location=' + [Uri]::new($propertiesPath).AbsoluteUri),
                ('--logging.file.name=' + (Join-Path $root ('logs/manual/api-release-' + [Guid]::NewGuid().ToString('N') + '.log'))))
            $child = [PayseDetachedStart]::Run($settings.javaPath, $argv, $root, 0)
            $process = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $child.ProcessId)
            if ($null -eq $process) { throw 'Released API exited before identity recording.' }
            return [pscustomobject]@{ pid = $process.ProcessId; path = $process.ExecutablePath;
                command = $process.CommandLine; started = $process.CreationDate.ToUniversalTime().ToString('o') }
        } finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
        }
    }
    $waitHealthy = {
        param($identity)
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
        do {
            $target = Get-ReleaseApiTarget -Config $configPath -Identity $identity
            if ($null -eq $target) { throw 'API exited before readiness.' }
            try { if ((Invoke-RestMethod -Uri $url -NoProxy -TimeoutSec 2).status -eq 'UP') { return } } catch { }
            Start-Sleep -Milliseconds 500
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        throw 'API readiness timed out.'
    }
    $backup = Join-Path $root ('releases/' + (Get-Date -Format yyyyMMdd-HHmmss) + '-' + [Guid]::NewGuid().ToString('N'))
    $applied = Invoke-ReleaseTransaction -JarPath $jarPath -RuntimePath $runtimePath -CandidatePath $candidate.jar `
        -Commit $ExpectedCommit -BackupDirectory $backup -ExpectedOldHash $oldHash `
        -ExpectedNewHash $candidate.release.sha256.'server.jar' -StopApi $stopApi -StartApi $startApi -WaitHealthy $waitHealthy
    foreach ($path in $before.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -ne $before[$path]) { throw 'A protected configuration changed concurrently.' }
    }
    $result.status = $applied.status
    $result.applied = $true
    $result.backup = $applied.backup
} catch {
    $result.status = 'FAILED'
    $result.reason = $_.Exception.Message
} finally {
    if ($resultPath) { Write-ReleaseJson $resultPath $result }
    if ($locks) { foreach ($lock in $locks) { $lock.Dispose() } }
    if ($deploymentLock) { $deploymentLock.Dispose() }
}
$result | ConvertTo-Json -Depth 6
if ($result.status -ne 'DEPLOYED') { exit 1 }
