# 2026-11-05: 관리자 터미널에서 디스크 보호의 비밀 없는 상태만 조회한다. 설정 변경·재부팅 없음.
param([string]$MountPoint = 'C:')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output '{"status":"ADMIN_REQUIRED","changed":false}'
    exit 1
}
try {
    $state = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction Stop
    @{
        status='VERIFIED'; changed=$false; protection=[string]$state.ProtectionStatus
        volumeStatus=[string]$state.VolumeStatus; percent=$state.EncryptionPercentage
        encryptionMethod=[string]$state.EncryptionMethod
        recoveryProtectorPresent=(@($state.KeyProtector | Where-Object {$_.KeyProtectorType -eq 'RecoveryPassword'}).Count -gt 0)
    } | ConvertTo-Json -Compress
} catch {
    Write-Output '{"status":"UNKNOWN","changed":false}'
    exit 1
}
