# 2026-11-05: 로컬 복구 도구의 비공개 파이프로만 PFX를 전달한다. 서버 파일은 변경하지 않는다.
param([ValidateSet('export','verify','import')][string]$Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$phase = 'read'
try {
    $inputText = [Console]::In.ReadToEnd()
    if ($inputText.Length -gt 1048576) { throw 'Recovery input is too large.' }
    $request = $inputText | ConvertFrom-Json
    if ([string]$request.password -eq '' -or $request.password.Length -lt 24) { throw 'Missing recovery password.' }
    $inputText = $null
    $created = $false
    if ($Action -eq 'export') {
        $phase = 'discover'
        $certificates = @(Get-ChildItem Cert:/CurrentUser/My | Where-Object {
            $_.HasPrivateKey -and (@($_.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) -contains '1.3.6.1.4.1.311.10.3.4')
        })
        if ($certificates.Count -eq 0) {
            $phase = 'create'
            $null = & "$env:SystemRoot/System32/cipher.exe" /k 2>&1
            if ($LASTEXITCODE -ne 0) { throw 'EFS certificate creation failed.' }
            $created = $true
            $certificates = @(Get-ChildItem Cert:/CurrentUser/My | Where-Object {
                $_.HasPrivateKey -and (@($_.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) -contains '1.3.6.1.4.1.311.10.3.4')
            })
        }
        if ($certificates.Count -lt 1 -or $certificates.Count -gt 32) { throw 'Unexpected EFS certificate count.' }
        $phase = 'export'
        $items = @($certificates | ForEach-Object {
            $pfx = $_.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, [string]$request.password)
            [pscustomobject]@{thumbprint=$_.Thumbprint; pfx=[Convert]::ToBase64String($pfx)}
            [Array]::Clear($pfx, 0, $pfx.Length)
        })
        $request | Add-Member -NotePropertyName certificates -NotePropertyValue $items -Force
    }
    if ($request.certificates.Count -lt 1 -or $request.certificates.Count -gt 32) { throw 'Missing EFS certificates.' }
    $verified = @()
    foreach ($item in $request.certificates) {
        $phase = 'ephemeralImport'
        $pfx = [Convert]::FromBase64String($item.pfx)
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$request.password, $flags)
        try {
            if (-not $certificate.HasPrivateKey -or $certificate.Thumbprint -ne $item.thumbprint) {
                throw 'EFS recovery certificate mismatch.'
            }
            $eku = @($certificate.Extensions | Where-Object {$_.Oid.Value -eq '2.5.29.37'})
            if ($eku.Count -ne 1 -or $eku[0].EnhancedKeyUsages.Value -notcontains '1.3.6.1.4.1.311.10.3.4') {
                throw 'Not an EFS recovery certificate.'
            }
            $private = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($certificate)
            $public = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
            try {
                $phase = 'privateKeyProbe'
                $probe = [Text.Encoding]::UTF8.GetBytes('PAYSE EFS recovery verification v1')
                $padding = [Security.Cryptography.RSAEncryptionPadding]::OaepSHA1
                $encrypted = $public.Encrypt($probe, $padding)
                $decrypted = $private.Decrypt($encrypted, $padding)
                if ([Convert]::ToBase64String($probe) -ne [Convert]::ToBase64String($decrypted)) {
                    throw 'EFS private key recovery failed.'
                }
            } finally { if ($private) {$private.Dispose()}; if ($public) {$public.Dispose()} }
            if ($Action -eq 'import') {
                $persist = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet -bor
                    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor
                    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
                $imported = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, [string]$request.password, $persist)
                $store = [Security.Cryptography.X509Certificates.X509Store]::new('My','CurrentUser')
                try { $store.Open('ReadWrite'); $store.Add($imported) }
                finally { $store.Close(); $imported.Dispose() }
            }
            $verified += $certificate.Thumbprint
        } finally { $certificate.Dispose(); [Array]::Clear($pfx, 0, $pfx.Length) }
    }
    if ($Action -eq 'export') {
        @{certificates=$items; created=$created; verifiedCount=$verified.Count} | ConvertTo-Json -Depth 5 -Compress
    } else { @{verifiedCount=$verified.Count} | ConvertTo-Json -Compress }
    $request = $null
} catch {
    [Console]::Error.WriteLine('EFS recovery failed at ' + $phase + ' (' + $_.Exception.GetType().Name + '); existing server files unchanged.')
    exit 1
}
