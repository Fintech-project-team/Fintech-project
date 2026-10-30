<#
2026-10-29: 로컬 개발 비밀 JSON을 현재 Windows 사용자 DPAPI로 보호한다.
사용: dev_server.py. 표준 입력/출력 파이프만 사용하며 파일·로그에 평문을 쓰지 않는다.
#>
param([Parameter(Mandatory=$true)][ValidateSet('protect','unprotect')][string]$Mode)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Security
    $inputText = [Console]::In.ReadToEnd()
    if ($Mode -eq 'protect') {
        $plain = [Text.Encoding]::UTF8.GetBytes($inputText)
        try {
            $sealed = [Security.Cryptography.ProtectedData]::Protect(
                $plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            [Console]::Out.Write([Convert]::ToBase64String($sealed))
        } finally { [Array]::Clear($plain, 0, $plain.Length) }
    } else {
        $sealed = [Convert]::FromBase64String($inputText)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $sealed, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Console]::Out.Write([Text.Encoding]::UTF8.GetString($plain)) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
} catch {
    [Console]::Error.WriteLine('Local credential protection failed.')
    exit 1
}
