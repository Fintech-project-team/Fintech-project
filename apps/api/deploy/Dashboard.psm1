#Requires -Version 7.2
Set-StrictMode -Version Latest
$script:MoonFrames=@{}

# Created 2026-11-01: fit Korean/ASCII text to a terminal row without wrapping.
function Format-PayseCell {
    param([string]$Text,[int]$Width)
    $Text=[regex]::Replace($Text,'[\x00-\x1f\x7f]',' ')
    $total=0
    foreach($char in $Text.ToCharArray()){$total+=if([int]$char -ge 0x1100 -and ([int]$char -lt 0x2580 -or [int]$char -gt 0x259f)){2}else{1}}
    $limit=if($total -gt $Width){$Width-3}else{$Width}
    $used=0
    $builder=[Text.StringBuilder]::new()
    foreach($char in $Text.ToCharArray()){
        $size=if([int]$char -ge 0x1100 -and ([int]$char -lt 0x2580 -or [int]$char -gt 0x259f)){2}else{1}
        if($used+$size -gt $limit){break}
        [void]$builder.Append($char); $used+=$size
    }
    if($total -gt $Width){[void]$builder.Append('...');$used+=3}
    return $builder.ToString()+(' '*[Math]::Max(0,$Width-$used))
}

# Created 2026-11-01: render a fixed 11-by-5 moon; used by the banner, not an astronomical clock.
function Get-PayseMoon {
    param([int]$Frame=0)
    $phase=(($Frame % 48)+48) % 48
    if($script:MoonFrames.ContainsKey($phase)){return $script:MoonFrames[$phase]}
    $angle=2*[Math]::PI*$phase/48
    $lightX=[Math]::Sin($angle)
    $lightZ=-[Math]::Cos($angle)
    $tones=@('░','▒','▓','█')
    $result=[Collections.Generic.List[string]]::new()
    for($row=0;$row -lt 5;$row++){
        $line=[Text.StringBuilder]::new()
        for($column=0;$column -lt 11;$column++){
            $centerX=($column-5)/5.4
            $centerY=($row-2)/2.25
            if($centerX*$centerX+$centerY*$centerY -gt 1){
                [void]$line.Append(' ')
                continue
            }
            $lit=0; $inside=0
            for($sy=0;$sy -lt 4;$sy++){
                for($sx=0;$sx -lt 4;$sx++){
                    $x=($column-5+($sx-1.5)/4)/5.4
                    $y=($row-2+($sy-1.5)/4)/2.25
                    $depth=1-$x*$x-$y*$y
                    if($depth -ge 0){
                        $inside++
                        if($x*$lightX+[Math]::Sqrt($depth)*$lightZ -gt 0){$lit++}
                    }
                }
            }
            $tone=if($inside){[int][Math]::Round(3*$lit/$inside)}else{0}
            [void]$line.Append($tones[$tone])
        }
        $result.Add($line.ToString())
    }
    $script:MoonFrames[$phase]=$result.ToArray()
    return $script:MoonFrames[$phase]
}

# Modified 2026-11-01: place one animated moon beside the fixed five-row ASCII logo; used by dashboard.
function Get-PayseBanner {
    param([int]$Frame=0)
    $lines=@(
        '    ____  ___ __  _______ ______',
        '   / __ \/   |\ \/ / ___// ____/',
        '  / /_/ / /| | \  /\__ \/ __/',
        ' / ____/ ___ | / /___/ / /___',
        '/_/   /_/  |_|/_//____/_____/'
    )
    $logoWidth=($lines | Measure-Object -Property Length -Maximum).Maximum
    $moon=@(Get-PayseMoon -Frame $Frame)
    for($row=0;$row -lt $lines.Count;$row++){
        $lines[$row]=$lines[$row].PadRight($logoWidth)+'     '+$moon[$row]
    }
    return $lines
}

# Created 2026-11-05: share pending/failed display states so every frame includes AI status.
function New-PayseMonitorState {
    param([switch]$Unavailable)
    $status=if($Unavailable){'확인 불가'}else{'확인 중'}
    $checked=if($Unavailable){[DateTimeOffset]::Now.ToString('o')}else{$null}
    $detail=if($Unavailable){'미검증'}else{'확인 중'}
    return [pscustomobject]@{
        checkedAt=$checked; db=$status; api=$status; https=$status; ai=$status
        dbPid=$null; apiPid=$null; httpsPid=$null; certificate=$detail; phone=$detail
    }
}

# Created 2026-11-01: create status-only dashboard rows; never read log contents or credentials.
# Modified 2026-11-05: show unknown for absent AI information from older status probes.
function Get-PayseDashboard {
    param($State,$Settings,[int]$Width=78,[int]$IntervalSeconds=5,[int]$Height=32,[int]$Frame=0)
    $Width=[Math]::Max(58,[Math]::Min(96,$Width))
    $rows=[Collections.Generic.List[object]]::new()
    $edge='+'+('-'*($Width-2))+'+'
    $add={param($text,$color='Gray') $rows.Add([pscustomobject]@{text=('| '+(Format-PayseCell $text ($Width-4))+' |');color=$color})}
    $border={ $rows.Add([pscustomobject]@{text=$edge;color='DarkCyan'}) }
    & $border
    foreach($line in (Get-PayseBanner -Frame $Frame)){
        $padding=[Math]::Max(0,[int][Math]::Floor((($Width-4)-$line.Length)/2))
        & $add ((' '*$padding)+$line) 'Cyan'
    }
    $checked='확인 중'
    if($State.PSObject.Properties['checkedAt'] -and $State.checkedAt){
        $checked=([DateTimeOffset]$State.checkedAt).ToLocalTime().ToString('MM-dd HH:mm:ss')
    }
    & $add ('LOCAL WORKSPACE  |  상태 확인 '+$checked) 'DarkGray'
    & $border
    $localReady=$State.db -eq '연결 수락 중' -and $State.api -eq '응답 정상 (생존 확인)'
    $summary=if($localReady){'LOCAL READY   DB 연결 수락 / API 생존 확인'}else{'CHECK NEEDED   서비스 상태를 확인해 주세요'}
    if(-not $localReady -and $State.PSObject.Properties['startStatus']){
        if($State.startStatus -eq 'FAIL'){$summary='START FAILED   '+$State.startMessage}
        elseif($State.startStatus -eq 'STARTING'){$summary='STARTING   독립 프로세스에서 기동 중'}
    }
    & $add $summary $(if($localReady){'Green'}else{'Yellow'})
    if($Height -ge 28){& $add ' '}
    $ai='미확인'
    $aiProperty=$State.PSObject.Properties['ai']
    if($null -ne $aiProperty -and $aiProperty.Value -is [string] -and
        -not [string]::IsNullOrWhiteSpace($aiProperty.Value)){$ai=$aiProperty.Value}
    foreach($item in @(@('DATABASE',$State.db,$State.dbPid),@('API',$State.api,$State.apiPid),@('HTTPS',$State.https,$State.httpsPid),@('AI',$ai,$null))){
        $color=if($item[1] -match '경고|중지|없음|불가|거부'){'Red'}elseif($item[1] -match '꺼짐|비활성|확인 중|미확인|필요'){'Yellow'}else{'Green'}
        $pidLabel=if($null -ne $item[2]){'  / PID '+$item[2]}else{''}
        & $add (('{0,-10} {1}{2}' -f $item[0],$item[1],$pidLabel)) $color
    }
    & $border
    if($Height -ge 28){& $add 'CONNECTIONS' 'Cyan'}
    & $add ('API        http://127.0.0.1:'+$Settings.apiPort)
    & $add ('DATABASE   127.0.0.1:'+$Settings.databasePort)
    & $add ('CERT       '+$State.certificate) 'DarkGray'
    & $add ('PHONE      '+$State.phone) 'DarkGray'
    if($Height -ge 28){& $add '외부 접속 완료 여부는 테스트폰에서 별도 확인합니다.' 'DarkGray'}
    & $border
    & $add ('[R] 새로고침   [L] 로그 폴더   [Q] 화면 닫기   / '+$IntervalSeconds+'초 갱신')
    & $add '전체 종료: Stop-PAYSE.cmd   |   화면만 닫으면 서비스 유지' 'DarkGray'
    if($Height -ge 28){& $add '표시는 DB 연결 수락·API 생존 확인 기준입니다.' 'DarkGray'}
    & $border
    return $rows.ToArray()
}

Export-ModuleMember -Function Format-PayseCell,Get-PayseMoon,Get-PayseBanner,New-PayseMonitorState,Get-PayseDashboard
