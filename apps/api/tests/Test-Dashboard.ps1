#Requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../deploy/Dashboard.psm1') -Force
$checks=0
$settings=[pscustomobject]@{apiPort=18000;databasePort=15400}

# Created 2026-11-05: fail the CI command on a display or monitor contract mismatch.
function Assert-Dashboard {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw $Message}
    $script:checks++
}

foreach($case in @('pending','failed','missing','null','empty','spaces','invalid','ready','disabled')){
    $state=New-PayseMonitorState
    $expected='미확인'; $color='Yellow'
    switch($case){
        'pending' {$expected='확인 중'}
        'failed' {$state=New-PayseMonitorState -Unavailable; $expected='확인 불가'; $color='Red'}
        'missing' {$state.PSObject.Properties.Remove('ai')}
        'null' {$state.ai=$null}
        'empty' {$state.ai=''}
        'spaces' {$state.ai='   '}
        'invalid' {$state.ai=[pscustomobject]@{runtimeReady=$true}}
        'ready' {$state.ai='준비 완료(재사용)'; $expected=$state.ai; $color='Green'}
        'disabled' {$state.ai='비활성'; $expected=$state.ai}
    }
    $before=$state | ConvertTo-Json -Compress
    foreach($height in @(23,32)){
        $rows=@(Get-PayseDashboard -State $state -Settings $settings -Width 78 -Height $height)
        $aiRows=@($rows | Where-Object text -Match '^\| AI\s')
        Assert-Dashboard ($aiRows.Count -eq 1) ('Exactly one AI row required: '+$case)
        Assert-Dashboard ($aiRows[0].text.Contains($expected)) ('AI state was misreported: '+$case)
        Assert-Dashboard ($aiRows[0].color -eq $color) ('AI status color was misleading: '+$case)
        Assert-Dashboard ($rows.Count -le $height) ('Dashboard exceeds terminal height: '+$case)
    }
    Assert-Dashboard (($state | ConvertTo-Json -Compress) -ceq $before) 'Rendering mutated probe data.'
}

$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot=Join-Path $temporaryRoot ('payse-dashboard-test-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    foreach($name in @('Dashboard.psm1','Watch-Payse.ps1')){
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('../deploy/'+$name)) -Destination (Join-Path $testRoot $name)
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'launch.json'),($settings | ConvertTo-Json))
    $stub=@'
function Get-PayseStatus {
    param([string]$Root)
    $mode=[IO.File]::ReadAllText((Join-Path $Root 'mode.txt'))
    if($mode -eq 'failed'){throw 'synthetic-sensitive-probe-error'}
    Start-Sleep -Milliseconds 100
    $state=[pscustomobject]@{
        checkedAt='2026-11-05T00:00:00Z';db='연결 수락 중';api='응답 정상 (생존 확인)'
        https='꺼짐';ai='준비 완료(재사용)';dbPid=11;apiPid=12;httpsPid=$null
        certificate='미검증';phone='미검증'
    }
    if($mode -eq 'legacy'){$state.PSObject.Properties.Remove('ai')}
    return $state
}
Export-ModuleMember -Function Get-PayseStatus
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'Status.psm1'),$stub)
    foreach($case in @('ready','legacy','json','failed')){
        [IO.File]::WriteAllText((Join-Path $testRoot 'mode.txt'),$case)
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})
        $info.UseShellExecute=$false
        $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true
        $info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.Encoding]::UTF8
        $info.StandardErrorEncoding=[Text.Encoding]::UTF8
        foreach($value in @('-NoLogo','-NoProfile','-NonInteractive','-File',
            (Join-Path $testRoot 'Watch-Payse.ps1'),'-Root',$testRoot,'-Once')){
            $info.ArgumentList.Add($value)
        }
        if($case -in @('json','failed')){$info.ArgumentList.Add('-Json')}
        $child=[Diagnostics.Process]::Start($info)
        try {
            $stdout=$child.StandardOutput.ReadToEndAsync()
            $stderr=$child.StandardError.ReadToEndAsync()
            if(-not $child.WaitForExit(20000)){
                $child.Kill()
                $child.WaitForExit()
                throw 'Synthetic monitor did not finish.'
            }
            $output=$stdout.Result
            $errorText=$stderr.Result
            Assert-Dashboard ([string]::IsNullOrWhiteSpace($errorText)) 'Monitor exposed a probe exception.'
            if($case -eq 'failed'){
                Assert-Dashboard ($child.ExitCode -eq 1) 'Failed one-shot probe was reported as success.'
                Assert-Dashboard (-not $output.Contains('synthetic-sensitive')) 'Probe error content leaked.'
            } else {
                Assert-Dashboard ($child.ExitCode -eq 0) ('One-shot monitor failed: '+$case)
                if($case -eq 'json'){
                    $state=$output | ConvertFrom-Json
                    Assert-Dashboard ($state.ai -ceq '준비 완료(재사용)') 'JSON probe lost AI state.'
                } else {
                    $expected=if($case -eq 'legacy'){'미확인'}else{'준비 완료(재사용)'}
                    Assert-Dashboard ($output.Contains($expected)) ('Rendered probe differs: '+$case)
                }
            }
        } finally {$child.Dispose()}
    }
    Write-Output ('PASS: '+$checks+' dashboard assertions.')
} finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if(-not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'payse-dashboard-test-*'){
        throw 'Refused cleanup outside the synthetic monitor directory.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
