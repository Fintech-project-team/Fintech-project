#Requires -Version 7.2
param([string]$Root=$PSScriptRoot,[ValidateRange(2,60)][int]$IntervalSeconds=5,[switch]$Once,[switch]$Json)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'Dashboard.psm1') -Force
$settings=Get-Content -LiteralPath (Join-Path $Root 'launch.json') -Raw | ConvertFrom-Json
$interactive=-not [Console]::IsOutputRedirected -and -not $Once -and -not $Json
$previousSize=''; $previousRows=@(); $previousFrame=-1; $previousCursor=$true
$state=New-PayseMonitorState
$clock=[Diagnostics.Stopwatch]::StartNew()
$probe=[PowerShell]::Create()
$pending=$null; $nextProbeAt=0; $refresh=$true; $statusChanged=$true; $quit=$false
$frameMilliseconds=140
if($interactive){
    try{$previousCursor=[Console]::CursorVisible;[Console]::CursorVisible=$false;[Console]::Title='PAYSE | Server Control'}catch{}
}

# Modified 2026-11-01: animate cached frames independently of one read-only status probe; used by Start-PAYSE.cmd.
try {
    while(-not $quit){
        if($interactive -and -not [Console]::IsInputRedirected){
            while([Console]::KeyAvailable){
                switch([Console]::ReadKey($true).Key){
                    'Q' {$quit=$true}
                    'R' {if($null -eq $pending){$refresh=$true}}
                    'L' {Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $Root 'logs/manual')+'"')}
                }
            }
        }
        if($quit){break}
        $finished=$false
        if($null -ne $pending -and $pending.IsCompleted){
            try {
                $received=@($probe.EndInvoke($pending))
                if($probe.HadErrors -or $received.Count -ne 1){throw 'Status probe failed'}
                $state=$received[0]
            } catch {
                # Clear stale success without rendering exception text or historical logs.
                $state=New-PayseMonitorState -Unavailable
                if($Once){exit 1}
            }
            $pending=$null; $finished=$true; $statusChanged=$true
            $nextProbeAt=$clock.ElapsedMilliseconds+1000*$IntervalSeconds
        }
        if($finished -and $Json){$state|ConvertTo-Json -Depth 6;break}
        if($null -eq $pending -and ($refresh -or $clock.ElapsedMilliseconds -ge $nextProbeAt)){
            $probe.Commands.Clear()
            $probe.Streams.Error.Clear()
            [void]$probe.AddScript({
                param($modulePath,$serverRoot)
                $ErrorActionPreference='Stop'
                Import-Module $modulePath -Force
                Get-PayseStatus -Root $serverRoot
            }).AddArgument((Join-Path $PSScriptRoot 'Status.psm1')).AddArgument($Root)
            $pending=$probe.BeginInvoke()
            $refresh=$false
        }
        $frame=if($interactive){[int][Math]::Floor($clock.ElapsedMilliseconds/$frameMilliseconds) % 48}else{12}
        $width=78; $height=32; $size='static'
        if($interactive){
            $width=[Math]::Min(96,[Math]::Max(1,[Console]::WindowWidth-2))
            $height=[Console]::WindowHeight
            $size=([Console]::WindowWidth.ToString()+'x'+$height)
        }
        if($interactive -and ($width -lt 58 -or $height -lt 23)){
            if($size -ne $previousSize){
                Clear-Host
                $hint='Enlarge window: 60 x 23'
                Write-Host $hint.Substring(0,[Math]::Min($width,$hint.Length)) -ForegroundColor DarkGray -NoNewline
                $previousSize=$size; $previousRows=@()
            }
        } elseif(($interactive -and ($frame -ne $previousFrame -or $size -ne $previousSize -or $statusChanged)) -or
                 (-not $interactive -and $finished)){
            $rows=@(Get-PayseDashboard -State $state -Settings $settings -Width $width -Height $height -IntervalSeconds $IntervalSeconds -Frame $frame)
            if($interactive){
                if($size -ne $previousSize){Clear-Host;$previousRows=@()}
                try {
                    for($row=0;$row -lt $rows.Count;$row++){
                        if($row -ge $previousRows.Count -or $rows[$row].text -cne $previousRows[$row].text -or
                           $rows[$row].color -ne $previousRows[$row].color){
                            [Console]::SetCursorPosition(0,$row)
                            Write-Host $rows[$row].text -ForegroundColor $rows[$row].color -NoNewline
                        }
                    }
                    $previousRows=$rows; $previousSize=$size
                } catch {
                    # Window resizing can invalidate cursor coordinates; repaint on the next frame.
                    $previousSize=''; $previousRows=@()
                }
            } else {
                foreach($row in $rows){Write-Host $row.text -ForegroundColor $row.color}
            }
            $previousFrame=$frame; $statusChanged=$false
        }
        if($finished -and $Once){break}
        Start-Sleep -Milliseconds 50
    }
} finally {
    # This disposes only the monitor's read-only worker; DB/API/HTTPS processes remain running.
    if($null -ne $pending){try{$probe.Stop()}catch{}}
    $probe.Dispose()
    if($interactive){try{[Console]::CursorVisible=$previousCursor;[Console]::SetCursorPosition(0,[Math]::Min($previousRows.Count,[Console]::WindowHeight-1))}catch{}}
}
