# Telegram-бот: по командам присылает подборки вакансий из data/jobs.json.
# Запуск: powershell -ExecutionPolicy Bypass -File bot.ps1
. "$PSScriptRoot\lib.ps1"

$s = Get-Secrets
if (-not $s -or -not $s.token -or $s.token -match 'ВСТАВЬ') {
    Write-Log 'Нет токена бота: заполни secrets.json (см. README.md)'
    exit 1
}

$EasyCountries = '^(Сербия|Армения|Казахстан|ОАЭ|Кипр)$'
$Help = @"
<b>Агент поиска работы</b>

/new — новые вакансии, которые ты ещё не видел
/top — лучшие (A и B) за 2 недели
/cn · /de · /nl · /ru — по стране
/easy — Сербия, Армения, Казахстан, ОАЭ, Кипр
/remote — удалённые
/find <i>слово</i> — поиск по названию и компании (например /find ethercat)
/search — запустить поиск сейчас (15–30 минут)
/stats — статистика
"@

function Get-Recent($days) {
    $since = (Get-Date).AddDays(-$days).ToString('yyyy-MM-dd HH:mm')
    @((Get-Jobs).Values | Where-Object { $_.found -ge $since })
}

function Get-Best($list) {
    @($list | Where-Object { $_.tier -in 'A', 'B' } | Sort-Object score -Descending)
}

function Invoke-BotCommand($chat, $text) {
    $cmd, $arg = ($text.Trim() -split '\s+', 2)
    $cmd = ($cmd -replace '@.*$', '').ToLower()
    switch ($cmd) {
        { $_ -in '/start', '/help' } { Send-Tg $chat $Help }

        '/new' {
            $jobs = Get-Jobs
            $list = @($jobs.Values | Where-Object { -not $_.shown -and $_.tier -ne 'C' } | Sort-Object score -Descending)
            Send-Tg $chat ("🆕 <b>Новые: $($list.Count)</b>`n`n" + (Format-JobList $list 15))
            foreach ($j in ($list | Select-Object -First 15)) { $j.shown = $true }
            Save-Jobs $jobs
        }

        '/top' {
            $list = Get-Best (Get-Recent 14)
            Send-Tg $chat ("🏆 <b>Лучшие за 2 недели: $($list.Count)</b>`n`n" + (Format-JobList $list 15))
        }

        { $_ -in '/cn', '/de', '/nl', '/ru' } {
            $c = @{ '/cn' = 'Китай'; '/de' = 'Германия'; '/nl' = 'Нидерланды'; '/ru' = 'Россия' }[$cmd]
            $list = Get-Best (Get-Recent 14 | Where-Object { $_.country -eq $c })
            Send-Tg $chat ("📍 <b>$c</b>, лучшие за 2 недели: $($list.Count)`n`n" + (Format-JobList $list 15))
        }

        '/easy' {
            $list = Get-Best (Get-Recent 14 | Where-Object { $_.country -match $EasyCountries })
            Send-Tg $chat ("✈️ <b>Страны без визовых сложностей</b>: $($list.Count)`n`n" + (Format-JobList $list 15))
        }

        '/remote' {
            $list = Get-Best (Get-Recent 14 | Where-Object { $_.remote })
            Send-Tg $chat ("🏠 <b>Удалённые</b>: $($list.Count)`n`n" + (Format-JobList $list 15))
        }

        '/find' {
            if (-not $arg) { Send-Tg $chat 'Напиши слово после команды, например: /find ethercat'; break }
            $re = [regex]::Escape($arg)
            $list = @((Get-Jobs).Values | Where-Object { "$($_.title) $($_.company) $($_.reasons)" -match "(?i)$re" } | Sort-Object score -Descending)
            Send-Tg $chat ("🔍 <b>$(ConvertTo-TgSafe $arg)</b>: $($list.Count)`n`n" + (Format-JobList $list 15))
        }

        '/search' {
            Send-Tg $chat '🔎 Запускаю поиск, это займёт 15–30 минут…'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'search.ps1') -NoNotify | Out-Null
            if ($LASTEXITCODE -eq 2) { Send-Tg $chat 'Поиск уже идёт (запущен по расписанию). Попробуй /new через несколько минут.'; break }
            $last = Read-JsonFile (Join-Path $DataDir 'last_run.json')
            $jobs = Get-Jobs
            $list = @($last.keys | ForEach-Object { $jobs[$_] } | Where-Object { $_ -and $_.tier -in 'A', 'B' } | Sort-Object score -Descending)
            Send-Tg $chat ("✅ Готово. Новых: $($last.total) (🟢 A: $($last.A), 🟡 B: $($last.B))`n`n" + (Format-JobList $list 10))
            foreach ($j in ($list | Select-Object -First 10)) { $j.shown = $true }
            Save-Jobs $jobs
        }

        '/stats' {
            $all = @((Get-Jobs).Values)
            $last = Read-JsonFile (Join-Path $DataDir 'last_run.json')
            $lines = $all | Group-Object country | Sort-Object Count -Descending | ForEach-Object {
                $a = @($_.Group | Where-Object { $_.tier -eq 'A' }).Count
                $b = @($_.Group | Where-Object { $_.tier -eq 'B' }).Count
                "$($_.Name): $($_.Count) (A: $a, B: $b)"
            }
            Send-Tg $chat ("📊 <b>В базе: $($all.Count)</b>`nПоследний поиск: $($last.time)`n`n" + ($lines -join "`n"))
        }

        default { Send-Tg $chat "Не знаю такой команды.`n`n$Help" }
    }
}

# ---------- основной цикл (long polling) ----------
$offsetFile = Join-Path $DataDir 'bot_offset.txt'
$offset = if (Test-Path $offsetFile) { [int64](Get-Content $offsetFile) } else { 0 }
Write-Log 'Бот запущен'

while ($true) {
    try { $u = Invoke-Tg 'getUpdates' @{ offset = $offset; timeout = 50; allowed_updates = @('message') } }
    catch { Write-Log "getUpdates: $($_.Exception.Message)"; Start-Sleep -Seconds 20; continue }

    foreach ($up in @($u.result)) {
        $offset = [int64]$up.update_id + 1
        Set-Content -Path $offsetFile -Value $offset
        $m = $up.message
        if (-not $m -or -not $m.text) { continue }
        $chat = [string]$m.chat.id
        $s = Get-Secrets

        # Пока chat_id не задан — только подсказываем его, данных не отдаём
        if (-not $s.chat_id) {
            Send-Tg $chat "Твой chat_id: <code>$chat</code>`nВпиши его в secrets.json и перезапусти бота."
            Write-Log "Запрос chat_id от $chat"
            continue
        }
        if ($chat -ne [string]$s.chat_id) { Write-Log "Сообщение из чужого чата $chat проигнорировано"; continue }

        Write-Log "Команда: $($m.text)"
        try { Invoke-BotCommand $chat $m.text }
        catch { Write-Log "Ошибка команды: $($_.Exception.Message)"; Send-Tg $chat "Ошибка: $(ConvertTo-TgSafe $_.Exception.Message)" }
    }
}
