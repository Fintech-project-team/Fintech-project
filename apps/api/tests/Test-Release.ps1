#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../deploy/Release-Control.psm1') -Force
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $temporaryRoot ('payse-release-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

try {
    $propertyFile = Join-Path $testRoot 'deployment.properties'
    [IO.File]::WriteAllText($propertyFile, 'deployment.installRoot=C\:\\server\u0020folder\\PAYSE')
    $decoded = Read-ReleaseProperties $propertyFile
    Assert-True ($decoded['deployment.installRoot'] -ceq 'C:\server folder\PAYSE') 'Java path escaping differs.'
    [IO.File]::WriteAllText($propertyFile, "same=one`nsame=two")
    $rejected = $false
    try { Read-ReleaseProperties $propertyFile } catch { $rejected = $true }
    Assert-True $rejected 'Duplicate properties were accepted.'

    $schema = Get-Content (Join-Path $PSScriptRoot '../deploy/release-schema.json') -Raw | ConvertFrom-Json
    $profiles = @{ 'spring.profiles.active' = 'database,auth,finance,salary-notices' }
    Assert-True ((Test-ReleaseProfiles $profiles $schema).Count -eq 4) 'Supported profiles were rejected.'
    $profiles['spring.profiles.active'] += ',analysis'
    $rejected = $false
    try { Test-ReleaseProfiles $profiles $schema } catch { $rejected = $true }
    Assert-True $rejected 'Unreviewed analysis profile was accepted.'

    foreach ($scenario in @('success', 'start-fails', 'stop-fails', 'recovery-fails', 'tampered')) {
        $scenarioRoot = Join-Path $testRoot $scenario
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        $jar = Join-Path $scenarioRoot 'server.jar'
        $candidate = Join-Path $scenarioRoot 'candidate.jar'
        $runtimePath = Join-Path $scenarioRoot 'runtime.json'
        $backup = Join-Path $scenarioRoot 'backup'
        [IO.File]::WriteAllText($jar, 'old')
        [IO.File]::WriteAllText($candidate, 'new')
        $oldHash = (Get-FileHash $jar).Hash
        $newHash = (Get-FileHash $candidate).Hash
        Write-ReleaseJson $runtimePath @{ jarSha256 = $oldHash; process = @{ pid = 1 }; configSha256 = 'unchanged' }
        if ($scenario -eq 'tampered') { [IO.File]::WriteAllText($candidate, 'tampered') }
        $script:starts = 0
        $script:stops = 0
        $stop = {
            param($identity)
            $script:stops++
            if ($scenario -eq 'stop-fails') { throw 'Simulated normal stop timeout.' }
        }
        $start = {
            param($state)
            $script:starts++
            if ($scenario -eq 'recovery-fails' -or ($scenario -eq 'start-fails' -and $script:starts -eq 1)) {
                throw 'Simulated start failure.'
            }
            return [pscustomobject]@{ pid = 100 + $script:starts }
        }
        $failure = $null
        try {
            $result = Invoke-ReleaseTransaction -JarPath $jar -RuntimePath $runtimePath -CandidatePath $candidate `
                -Commit ('a' * 40) -BackupDirectory $backup -ExpectedOldHash $oldHash -ExpectedNewHash $newHash `
                -StopApi $stop -StartApi $start -WaitHealthy { param($identity) }
        } catch { $failure = $_.Exception.Message }
        if ($scenario -eq 'success') {
            Assert-True ($null -eq $failure -and $result.status -eq 'DEPLOYED') 'Successful transaction failed.'
            Assert-True ([IO.File]::ReadAllText($jar) -eq 'new') 'Candidate was not installed.'
        } else {
            Assert-True ($null -ne $failure) 'An unsuccessful transaction was reported as successful.'
            Assert-True ([IO.File]::ReadAllText($jar) -eq 'old') 'Previous JAR was not preserved/restored.'
        }
        if ($scenario -eq 'start-fails') {
            Assert-True ($failure -match 'previous JAR was restored and is healthy' -and $script:starts -eq 2) 'Rollback did not restart old JAR.'
        }
        if ($scenario -eq 'stop-fails') { Assert-True ($script:starts -eq 0) 'Startup happened despite shutdown failure.' }
        if ($scenario -eq 'tampered') { Assert-True ($script:stops -eq 0) 'Shutdown happened despite tampering.' }
        if ($scenario -eq 'recovery-fails') {
            Assert-True ($failure -match 'automatic recovery did not complete') 'Recovery failure was hidden.'
        }
        $after = Get-Content $runtimePath -Raw | ConvertFrom-Json
        Assert-True ($after.configSha256 -eq 'unchanged') 'Configuration identity changed.'
        if ($scenario -ne 'tampered') { Assert-True ([IO.File]::ReadAllText((Join-Path $backup 'server.jar')) -eq 'old') 'Backup lost.' }
    }
    Write-Output ("PASS: " + $checks + " Windows deployment assertions.")
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'payse-release-test-*') {
        throw 'Refused cleanup outside the verified test directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
