# 2026-11-05: 지정한 경로의 OS 저장 보호 상태만 읽는다. 인증서/키/파일을 변경하지 않는다.
param([string[]]$Path = @())
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PayseStorageProtection {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force
    $parent = $item
    while ($null -ne $parent) {
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Test-Path -LiteralPath (Join-Path $parent.FullName '.git'))) {
            throw 'Use an ordinary private path outside Git.'
        }
        $parent = if ($parent -is [IO.DirectoryInfo]) { $parent.Parent } else { $parent.Directory }
    }
    $volume = 'Unknown'
    $mount = [IO.Path]::GetPathRoot($item.FullName)
    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        try {
            $state = Get-BitLockerVolume -MountPoint $mount -ErrorAction Stop
            if ($null -ne $state -and [string]$state.ProtectionStatus -eq 'On' -and
                [string]$state.VolumeStatus -eq 'FullyEncrypted') {
                $volume = 'VerifiedOn'
            } elseif ($null -ne $state) { $volume = 'NotFullyProtected' }
        } catch { $volume = 'Unknown' }
    }
    [pscustomobject]@{
        kind = if ($item -is [IO.DirectoryInfo]) { 'directory' } else { 'file' }
        efsEncrypted = (($item.Attributes -band [IO.FileAttributes]::Encrypted) -ne 0)
        volumeProtection = $volume
        coverage = 'specifiedPathOnly'
        recoveryVerified = $false
    }
}

if ($Path.Count -gt 0) {
    $results = @($Path | ForEach-Object { Get-PayseStorageProtection -LiteralPath $_ })
    ConvertTo-Json -InputObject $results -Depth 3
}
