# Поиск вакансий по критериям из config.psd1.
# Запуск: powershell -ExecutionPolicy Bypass -File search.ps1 [-NoNotify] [-Days 30]
#         search.ps1 -Rescore [-MaxDetails 150]  — пересчитать оценки базы по текущему config.psd1
param([switch]$NoNotify, [int]$Days = 0, [switch]$Rescore, [int]$MaxDetails = 0)

. "$PSScriptRoot\lib.ps1"
$cfg = Get-Config
if ($Days -le 0) { $Days = $cfg.PeriodDays }

# Не даём запустить два поиска одновременно (бот + расписание)
$lock = Join-Path $DataDir 'search.lock'
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes -lt 60) {
    Write-Log 'Поиск уже идёт, пропускаю запуск'
    exit 2
}
Set-Content -Path $lock -Value $PID

function Set-JobText($j, $text) {
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
    $j | Add-Member -NotePropertyName text -NotePropertyValue $text -Force
}

try {
    if ($Rescore) {
        if ($MaxDetails -le 0) { $MaxDetails = $cfg.MaxDetailsPerRun }
        $jobs = Get-Jobs
        foreach ($k in @($jobs.Keys)) {
            $t = $jobs[$k].title
            if ($t -notmatch $cfg.TitleInclude -or $t -match $cfg.TitleExclude) { $jobs.Remove($k) }
        }
        $i = 0
        # Сначала дочитываем зарубежные (LinkedIn быстрый), потом hh.ru
        foreach ($j in ($jobs.Values | Sort-Object @{ e = { if ($_.source -eq 'linkedin') { 0 } else { 1 } } })) {
            $text = "$($j.text)"
            if ((-not $j.checked -or -not $text) -and $j.source -notin 'arbeitnow', 'telegram' -and $i -lt $MaxDetails) {
                $text = Get-JobText $j
                $j.checked = $true
                Set-JobText $j $text
                $i++
                Start-Sleep -Milliseconds 1200
            }
            Set-JobScore $j $text $cfg
        }
        Save-Jobs $jobs
        $all = @($jobs.Values)
        Write-Log ("Пересчёт: в базе {0}, дочитано {1}, A: {2}, B: {3}" -f $all.Count, $i, @($all | Where-Object { $_.tier -eq 'A' }).Count, @($all | Where-Object { $_.tier -eq 'B' }).Count)
        return
    }

    Write-Log "Поиск начат (за $Days дн.)"
    $jobs = Get-Jobs
    $found = @()

    foreach ($q in $cfg.LinkedIn) {
        $r = @(Search-LinkedIn $q.Q $q.Loc $q.Country $Days ([bool]$q.Remote))
        Write-Log ("LinkedIn  {0} / {1}: {2}" -f $q.Q, $q.Loc, $r.Count)
        $found += $r
    }
    foreach ($q in $cfg.HHQueries) {
        foreach ($a in $cfg.HHAreas) {
            $r = @(Search-HH $q $a $Days)
            Write-Log ("hh.ru     {0} / area {1}: {2}" -f $q, $a, $r.Count)
            $found += $r
        }
    }
    $r = @(Search-Arbeitnow $cfg.ArbeitnowPages | Where-Object { $_.country -match $cfg.ArbeitnowCountries })
    Write-Log "Arbeitnow (DE/NL): $($r.Count)"
    $found += $r
    foreach ($q in $cfg.BAQueries) {
        $r = @(Search-BA $q $Days)
        Write-Log ("Bundesagentur {0}: {1}" -f $q, $r.Count)
        $found += $r
    }
    foreach ($ch in $cfg.TelegramChannels) {
        $r = @(Search-Telegram $ch $Days)
        Write-Log ("Telegram  @{0}: {1}" -f $ch, $r.Count)
        $found += $r
    }

    # Фильтр по названию и отбрасывание уже известных
    $new = @{}
    foreach ($j in $found) {
        if ($j.title -notmatch $cfg.TitleInclude -or $j.title -match $cfg.TitleExclude) { continue }
        if ($jobs.ContainsKey($j.key) -or $new.ContainsKey($j.key)) { continue }
        $new[$j.key] = $j
    }
    Write-Log "Всего найдено: $($found.Count), новых подходящих по названию: $($new.Count)"

    # Оценка: первые MaxDetailsPerRun читаем целиком, остальные — по названию
    $i = 0
    $ordered = $new.Values | Sort-Object @{ e = { if ($_.title -match $cfg.TitleStrong) { 0 } elseif ($_.title -match $cfg.TitleEmbedded) { 1 } else { 2 } } }
    foreach ($j in $ordered) {
        $text = ''
        if ($i -lt $cfg.MaxDetailsPerRun) {
            $text = Get-JobText $j
            $j.checked = $true
            $i++
            if ($j.source -notin 'arbeitnow', 'telegram') { Start-Sleep -Milliseconds 1200 }
        }
        Set-JobScore $j $text $cfg
        Set-JobText $j "$text"
        if ($j.PSObject.Properties['_text']) { $j.PSObject.Properties.Remove('_text') }
        $jobs[$j.key] = $j
    }
    Save-Jobs $jobs

    $newList = @($new.Values | Sort-Object score -Descending)
    $a = @($newList | Where-Object { $_.tier -eq 'A' }).Count
    $b = @($newList | Where-Object { $_.tier -eq 'B' }).Count
    Write-JsonFile (Join-Path $DataDir 'last_run.json') @{ time = (Get-Date -Format 'yyyy-MM-dd HH:mm'); total = $newList.Count; A = $a; B = $b; keys = @($newList | ForEach-Object { $_.key }) }
    Write-Log "Готово: новых $($newList.Count) (A: $a, B: $b)"

    # Уведомление в Telegram
    if (-not $NoNotify -and (Test-TelegramReady)) {
        Send-RunReport $newList $null
        foreach ($j in $newList) { $j.notified = $true }
        Save-Jobs $jobs
    }
}
finally {
    Remove-Item $lock -ErrorAction SilentlyContinue
}
