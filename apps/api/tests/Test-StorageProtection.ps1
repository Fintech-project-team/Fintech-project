# 2026-11-05: 실제 디스크 보호를 변경하지 않고 상태 오인·Git 경계를 검사한다.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../tools/storage_protection.ps1')
$testPath = Join-Path ([IO.Path]::GetTempPath()) ('payse-protection-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testPath
try {
    $file = Join-Path $testPath 'synthetic.txt'
    [IO.File]::WriteAllText($file, 'synthetic-only')
    function Get-BitLockerVolume { param($MountPoint, $ErrorAction) throw 'synthetic access denied' }
    $status = Get-PayseStorageProtection -LiteralPath $file
    if ($status.volumeProtection -ne 'Unknown' -or $status.recoveryVerified) { throw 'Protection was overstated.' }
    if ([IO.File]::ReadAllText($file) -ne 'synthetic-only') { throw 'Input changed.' }
    function Get-BitLockerVolume { param($MountPoint, $ErrorAction)
        [pscustomobject]@{ ProtectionStatus = 'On'; VolumeStatus = 'FullyEncrypted' }
    }
    if ((Get-PayseStorageProtection -LiteralPath $file).volumeProtection -ne 'VerifiedOn') { throw 'Verified state lost.' }
    $null = New-Item -ItemType Directory -Path (Join-Path $testPath '.git')
    $rejected = $false
    try { Get-PayseStorageProtection -LiteralPath $file | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Git path accepted.' }
    Write-Output 'PASS: storage protection inspection (unknown, verified, unchanged, Git boundary).'
} finally {
    Remove-Item Function:Get-BitLockerVolume -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testPath)
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -notlike 'payse-protection-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
