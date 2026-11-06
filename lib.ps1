# Общие функции агента поиска работы: загрузка страниц, парсинг площадок, оценка, хранилище, Telegram.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # без прогресс-бара Invoke-WebRequest в разы быстрее
$Root    = $PSScriptRoot
$DataDir = Join-Path $Root 'data'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory $DataDir | Out-Null }
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

# ---------- служебное ----------

function Write-Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    Add-Content -Path (Join-Path $DataDir 'agent.log') -Value $line -Encoding UTF8
    Write-Host $line
}

function Read-JsonFile($path) {
    if (Test-Path $path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } else { $null }
}

function Write-JsonFile($path, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 6
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-Config { Import-PowerShellDataFile (Join-Path $Root 'config.psd1') }

function Get-Html($url) {
    for ($i = 0; $i -lt 3; $i++) {
        try { return (Invoke-WebRequest -Uri $url -UserAgent $UA -UseBasicParsing -TimeoutSec 40).Content }
        catch { Start-Sleep -Seconds (3 * ($i + 1)) }
    }
    Write-Log "WARN: не удалось загрузить $url"
    return $null
}

function ConvertFrom-Html($s) {
    if (-not $s) { return '' }
    $t = $s -replace '<br\s*/?>|</li>|</p>|</h\d>', "`n" -replace '<li[^>]*>', '• ' -replace '<[^>]+>', ' '
    ([System.Net.WebUtility]::HtmlDecode($t) -replace '[ \t ]+', ' ' -replace '\s*\n\s*', "`n").Trim()
}

function Get-MaxNumber($s) {
    $m = [regex]::Matches(($s -replace '[\s  ]', ''), '\d{5,7}')
    if ($m.Count) { [int]$m[$m.Count - 1].Value } else { 0 }
}

# ---------- хранилище ----------

function New-Job($source, $id, $title, $company, $location, $country, $url) {
    [pscustomobject]@{
        key = "$source`:$id"; source = $source; id = "$id"
        title = $title; company = $company; location = $location; country = $country; url = $url
        salary = ''; salary_max = 0; remote = $false; exp = ''
        found = (Get-Date -Format 'yyyy-MM-dd HH:mm'); score = 0; tier = 'C'
        reasons = ''; flags = ''; checked = $false; notified = $false; shown = $false; text = ''
    }
}

function Get-Jobs {
    $h = @{}
    $arr = Read-JsonFile (Join-Path $DataDir 'jobs.json')
    if ($arr) {
        foreach ($j in @($arr)) {
            # PowerShell 7 может превратить строку даты в DateTime — возвращаем строку
            if ($j.found -is [datetime]) { $j.found = $j.found.ToString('yyyy-MM-dd HH:mm') }
            $h[$j.key] = $j
        }
    }
    $h
}

# Компактные данные для Mini App (без полного текста)
function Get-AppData($jobs) {
    $list = @($jobs.Values | Sort-Object @{ e = { $_.score }; Descending = $true } | ForEach-Object {
        $x = "$($_.text)"
        if ($x.Length -gt 1500) { $x = $x.Substring(0, 1500) + '…' }
        [ordered]@{
            k = $_.key; t = $_.title; c = $_.company; l = $_.location; co = $_.country; u = $_.url
            sa = $_.salary; e = $_.exp; r = [bool]$_.remote; f = $_.found; sc = $_.score; ti = $_.tier
            re = $_.reasons; fl = $_.flags; src = $_.source; x = $x
        }
    })
    [ordered]@{ updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); jobs = $list }
}

function Save-Jobs($jobs) {
    $list = @($jobs.Values | Sort-Object @{ e = { $_.found }; Descending = $true }, @{ e = { $_.score }; Descending = $true })
    Write-JsonFile (Join-Path $DataDir 'jobs.json') $list
    # Копия для Excel (разделитель «;», UTF-8 с BOM)
    $csv = $list | Select-Object tier, score, country, location, company, title, salary, exp, remote, flags, reasons, url, found |
        ConvertTo-Csv -Delimiter ';' -NoTypeInformation
    [IO.File]::WriteAllLines((Join-Path $DataDir 'jobs.csv'), $csv, (New-Object Text.UTF8Encoding $true))
}

# ---------- площадки ----------

function Search-LinkedIn($q, $loc, $country, $days, [bool]$remote) {
    $res = @()
    $sec = $days * 86400
    foreach ($start in 0, 25) {
        $u = "https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search?keywords=$([uri]::EscapeDataString($q))&location=$([uri]::EscapeDataString($loc))&f_TPR=r$sec&start=$start"
        if ($remote) { $u += '&f_WT=2' }
        $h = Get-Html $u
        if (-not $h) { break }
        $cards = @([regex]::Split($h, '<li>') | Select-Object -Skip 1)
        if ($cards.Count -eq 0) { break }
        foreach ($c in $cards) {
            $id = [regex]::Match($c, 'jobPosting:(\d+)').Groups[1].Value
            if (-not $id) { $id = [regex]::Match($c, '/jobs/view/[^"?]*?(\d{8,})').Groups[1].Value }
            $t  = ConvertFrom-Html ([regex]::Match($c, 'base-search-card__title[^>]*>(.*?)</h3>', 's').Groups[1].Value)
            $co = ConvertFrom-Html ([regex]::Match($c, 'base-search-card__subtitle[^>]*>(.*?)</h4>', 's').Groups[1].Value)
            $lc = ConvertFrom-Html ([regex]::Match($c, 'job-search-card__location[^>]*>(.*?)</span>', 's').Groups[1].Value)
            if ($id -and $t) {
                $j = New-Job 'linkedin' $id $t $co $lc $country "https://www.linkedin.com/jobs/view/$id"
                $j.remote = $remote
                $res += $j
            }
        }
        Start-Sleep -Milliseconds 1500
    }
    $res
}

function Search-HH($q, $area, $days) {
    $res = @()
    foreach ($page in 0, 1) {
        $u = "https://hh.ru/search/vacancy?text=$([uri]::EscapeDataString($q))&area=$area&page=$page&search_period=$days&items_on_page=50"
        $h = Get-Html $u
        if (-not $h) { break }
        $parts = @($h -split 'data-qa="serp-item__title"' | Select-Object -Skip 1)
        if ($parts.Count -eq 0) { break }
        foreach ($p in $parts) {
            $id = [regex]::Match($p, 'hh\.ru/vacancy/(\d+)').Groups[1].Value
            if (-not $id) { continue }
            $chunk = $p.Substring(0, [Math]::Min(9000, $p.Length))
            $title = ConvertFrom-Html ([regex]::Match($chunk, 'serp-item__title-text"[^>]*>(.*?)</span>', 's').Groups[1].Value)
            $emp   = ConvertFrom-Html ([regex]::Match($chunk, 'vacancy-employer-text"[^>]*>(.*?)</span>', 's').Groups[1].Value)
            $addr  = ConvertFrom-Html ([regex]::Match($chunk, 'vacancy-serp__vacancy-address"[^>]*>(.*?)</span>', 's').Groups[1].Value)
            $plain = (ConvertFrom-Html $chunk) -replace '\s+', ' '
            $j = New-Job 'hh' $id $title $emp $addr 'Россия' "https://hh.ru/vacancy/$id"
            $sal = [regex]::Match($plain, '(?<![\d])((?:от\s*)?\d{1,3}(?:[   ]\d{3})+(?:\s*–\s*\d{1,3}(?:[   ]\d{3})+)?\s*₽|до\s*\d{1,3}(?:[   ]\d{3})+\s*₽)').Groups[1].Value
            $j.salary = $sal
            $j.salary_max = Get-MaxNumber $sal
            $j.remote = [bool]($plain -match '(?i)можно удал[её]нно|удал[её]нно')
            $j.exp = [regex]::Match($plain, '(Опыт\s*\d\s*[-–]\s*\d\s*(?:года|лет)|Опыт более 6 лет|Без опыта)').Groups[1].Value
            $res += $j
        }
        if ($parts.Count -lt 50) { break }   # вторая страница нужна, только если первая заполнена
        Start-Sleep -Milliseconds 1500
    }
    $res
}

function Get-ArbeitnowCountry($url, $location) {
    if ($url -match 'arbeitnow\.nl') { return 'Нидерланды' }
    if ($url -match 'arbeitnow\.co\.uk') { return 'Великобритания' }
    if ($url -match 'arbeitnow\.fr') { return 'Франция' }
    if ($location -match '(?i)switzerland|schweiz|zurich|zürich|bern|basel|genf|geneva|lausanne') { return 'Швейцария' }
    'Германия'
}

function Search-Arbeitnow($pages) {
    $res = @()
    for ($p = 1; $p -le $pages; $p++) {
        try { $r = Invoke-RestMethod -Uri "https://www.arbeitnow.com/api/job-board-api?page=$p" -TimeoutSec 40 } catch { break }
        if (-not $r.data) { break }
        foreach ($d in $r.data) {
            $country = Get-ArbeitnowCountry $d.url $d.location
            $j = New-Job 'arbeitnow' $d.slug $d.title $d.company_name $d.location $country $d.url
            $j.remote = [bool]$d.remote
            $j | Add-Member -NotePropertyName _text -NotePropertyValue (ConvertFrom-Html ([System.Net.WebUtility]::HtmlDecode($d.description)))
            $res += $j
        }
    }
    $res
}

# Страна по тексту объявления (для Telegram-каналов, где нет поля «страна»)
function Get-CountryFromText($s) {
    $map = [ordered]@{
        'Китай'      = '(?i)\bchina\b|китай|shanghai|shenzhen|beijing|hangzhou|шанхай|пекин|шэньчжэнь'
        'Германия'   = '(?i)\bgermany\b|deutschland|германи|berlin|munich|münchen|берлин|мюнхен'
        'Нидерланды' = '(?i)netherlands|amsterdam|eindhoven|rotterdam|нидерланд|амстердам'
        'Сербия'     = '(?i)serbia|belgrade|novi sad|серби|белград'
        'Армения'    = '(?i)armenia|yerevan|армени|ереван'
        'Казахстан'  = '(?i)kazakhstan|almaty|astana|казахстан|алмат|астан'
        'ОАЭ'        = '(?i)\buae\b|dubai|abu dhabi|оаэ|дубай|абу-даби'
        'Кипр'       = '(?i)cyprus|limassol|кипр|лимассол'
        'Россия'     = '(?i)москв|санкт-петербург|россия|\bрф\b'
    }
    foreach ($k in $map.Keys) { if ($s -match $map[$k]) { return $k } }
    'Не указано'
}

# Открытые Telegram-каналы с вакансиями (веб-версия t.me/s/<канал>, без входа)
function Search-Telegram($channel, $days) {
    $res = @()
    $since = (Get-Date).ToUniversalTime().AddDays(-$days)
    $h = Get-Html "https://t.me/s/$channel"
    if (-not $h) { return $res }
    foreach ($p in @([regex]::Split($h, 'data-post="') | Select-Object -Skip 1)) {
        $post = [regex]::Match($p, '^([^"]+)"').Groups[1].Value
        if (-not $post) { continue }
        $dt = [regex]::Match($p, 'datetime="([^"]+)"').Groups[1].Value
        if ($dt) { try { if ([datetime]::Parse($dt).ToUniversalTime() -lt $since) { continue } } catch {} }
        $text = ConvertFrom-Html ([regex]::Match($p, 'tgme_widget_message_text[^>]*>(.*?)</div>', 's').Groups[1].Value)
        if (-not $text) { continue }
        # Заголовок — первая содержательная строка без хэштегов и эмодзи
        $lines = @($text -split "`n" | ForEach-Object { ($_ -replace '#\S+', '' -replace '[^\p{L}\p{N}\s\-/().,+&:|@]', '').Trim() } | Where-Object { $_.Length -ge 4 })
        if (-not $lines) { continue }
        $title = $lines[0]; $company = "@$channel"
        $m = [regex]::Match($title, '^(.+?)\s+(?:/|\||@|—|–)\s+(.+)$')
        if ($m.Success) { $title = $m.Groups[1].Value.Trim(); $company = $m.Groups[2].Value.Trim() }
        if ($title.Length -gt 120) { $title = $title.Substring(0, 120) }
        $id = ($post -split '/')[-1]
        $j = New-Job 'telegram' "$channel`_$id" $title $company "t.me/$channel" (Get-CountryFromText $text) "https://t.me/$post"
        $j.remote = [bool]($text -match '(?i)\bremote\b|удал[её]н')
        $j | Add-Member -NotePropertyName _text -NotePropertyValue $text
        $res += $j
    }
    $res
}

# Bundesagentur für Arbeit — крупнейшая база вакансий Германии.
# X-API-Key 'jobboerse-jobsuche' — общий публичный идентификатор из открытой документации API (bund.dev), не секрет.
$BaHeaders = @{ 'X-API-Key' = 'jobboerse-jobsuche' }
function Search-BA($q, $days) {
    $res = @()
    $u = "https://rest.arbeitsagentur.de/jobboerse/jobsuche-service/pc/v4/jobs?was=$([uri]::EscapeDataString($q))&veroeffentlichtseit=$([Math]::Min($days, 100))&size=100&angebotsart=1"
    try { $r = Invoke-RestMethod -Uri $u -Headers $BaHeaders -UserAgent $UA -TimeoutSec 40 }
    catch { Write-Log "WARN: Bundesagentur недоступна: $($_.Exception.Message)"; return $res }
    foreach ($s in @($r.stellenangebote)) {
        if (-not $s.refnr -or -not $s.titel) { continue }
        $loc = (@($s.arbeitsort.ort, $s.arbeitsort.region) | Where-Object { $_ } | Select-Object -Unique) -join ', '
        $res += New-Job 'ba' $s.refnr $s.titel $s.arbeitgeber $loc 'Германия' "https://www.arbeitsagentur.de/jobsuche/jobdetail/$($s.refnr)"
    }
    $res
}

# Полный текст вакансии (для оценки требований)
function Get-JobText($job) {
    switch ($job.source) {
        'linkedin' {
            $h = Get-Html "https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/$($job.id)"
            return ConvertFrom-Html ([regex]::Match("$h", 'show-more-less-html__markup[^>]*>(.*?)</div>', 's').Groups[1].Value)
        }
        'hh' {
            $h = Get-Html $job.url
            $fmt = [regex]::Match("$h", 'Формат работы:\s*([^<]+)').Groups[1].Value
            if ($fmt -match 'удал') { $job.remote = $true }
            return ConvertFrom-Html ([regex]::Match("$h", 'data-qa="vacancy-description"[^>]*>(.*?)</div>\s*</div>', 's').Groups[1].Value)
        }
        'arbeitnow' { return $job._text }
        'telegram' { return $job._text }
        'ba' {
            try {
                $enc = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($job.id))
                $d = Invoke-RestMethod -Uri "https://rest.arbeitsagentur.de/jobboerse/jobsuche-service/pc/v4/jobdetails/$enc" -Headers $BaHeaders -UserAgent $UA -TimeoutSec 40
                $t = "$($d.stellenangebotsBeschreibung)$($d.stellenbeschreibung)"
                if ($t) { return ConvertFrom-Html $t }
            } catch {}
            $h = Get-Html $job.url
            $body = [regex]::Match("$h", '<body[^>]*>(.*)</body>', 's').Groups[1].Value -replace '(?s)<script.*?</script>|<style.*?</style>', ''
            return ConvertFrom-Html $body
        }
    }
    ''
}

# ---------- оценка ----------

function Set-JobScore($job, $text, $cfg) {
    $s = 0; $reasons = @(); $block = @(); $notes = @()
    $title = $job.title
    if ($title -match $cfg.TitleStrong) { $s += 3; $reasons += 'приводы/роботы/motion' }
    if ($title -match $cfg.TitleEmbedded) { $s += 2 }

    $hits = @([regex]::Matches("$title`n$text", $cfg.Skills) | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
    if ($hits.Count) { $s += [Math]::Min(4, $hits.Count); $reasons += ($hits -join ', ') }

    # Требуемый опыт
    $yrs = $null
    if ($job.exp -match 'более 6') { $yrs = 6 }
    elseif ($job.exp -match '3\s*[-–]\s*6') { $yrs = 3 }
    elseif ($job.exp -match '1\s*[-–]\s*3') { $yrs = 1 }
    elseif ($job.exp -match 'Без опыта') { $yrs = 0 }
    elseif ($job.exp -match '^(\d+)\+ лет') { $yrs = [int]$Matches[1] }
    elseif ($text) {
        $m = [regex]::Match($text, $cfg.YearsRegex)
        if ($m.Success) {
            $v = if ($m.Groups[1].Value) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ([int]$v -le 15) { $yrs = [int]$v; $job.exp = "$yrs+ лет" }
        }
    }
    if ($null -ne $yrs) {
        if ($yrs -ge 5) { $block += "опыт $yrs+ лет" }
        elseif ($yrs -ge 3) { $s -= 1; $notes += "опыт $yrs+" }
        else { $s += 1 }
    }

    # Языки и сфера
    if ($text -match $cfg.GermanFluent) { $block += 'нужен немецкий' }
    if ($text -match $cfg.DutchFluent) { $block += 'нужен нидерландский' }
    # Описание целиком на немецком / нидерландском — язык почти наверняка нужен (пометка, не отсев)
    if ("$text".Length -gt 300) {
        $en = [regex]::Matches($text, '(?i)\b(and|the|with|you|our|experience|will|are|team)\b').Count
        $de = [regex]::Matches($text, '(?i)\b(und|der|die|das|mit|für|wir|ihre|eine|oder|sowie|kenntnisse)\b').Count
        $nl = [regex]::Matches($text, '(?i)\b(het|een|wij|voor|naar|ervaring|kennis|bij|zijn)\b').Count
        if ($de -gt 15 -and $de -gt 2 * $en) { $s -= 2; $notes += 'описание на немецком' }
        elseif ($nl -gt 15 -and $nl -gt 2 * $en) { $s -= 2; $notes += 'описание на нидерландском' }
    }
    if ($job.country -eq 'Китай' -and ([regex]::Matches("$title $text", '[一-鿿]').Count -gt 80)) { $s -= 1; $notes += 'описание на китайском' }
    if ("$title $($job.company) $text" -match $cfg.Defense) { $block += 'оборонка/БПЛА' }

    # Зарплата (Россия). Больше 2 млн ₽ — ошибка разбора, не учитываем
    if ($job.salary_max -gt 2000000) { $job.salary_max = 0; $job.salary = '' }
    if ($job.salary_max -gt 0) {
        if ($job.salary_max -ge $cfg.RuSalaryGood) { $s += 2; $reasons += 'зарплата' }
        elseif ($job.salary_max -lt $cfg.RuSalaryMin) { $s -= 2; $notes += 'зарплата ниже текущей' }
    }
    if ($job.remote) { $s += 1; $reasons += 'удалёнка' }
    $cb = $cfg.CountryBonus[[string]$job.country]
    if ($cb) { $s += $cb; $reasons += 'целевая страна' }

    $job.score = $s
    $job.reasons = ($reasons -join '; ')
    $job.flags = (@($block) + @($notes)) -join '; '
    $job.tier = if ($block.Count) { 'C' } elseif ($s -ge 6) { 'A' } elseif ($s -ge 3) { 'B' } else { 'C' }
}

# ---------- Telegram ----------

function Get-Secrets {
    # В GitHub Actions токен и chat_id приходят из секретов репозитория
    if ($env:TG_TOKEN) { return [pscustomobject]@{ token = $env:TG_TOKEN; chat_id = $env:TG_CHAT_ID } }
    Read-JsonFile (Join-Path $Root 'secrets.json')
}

function Test-TelegramReady {
    $s = Get-Secrets
    [bool]($s -and $s.token -and $s.token -notmatch 'ВСТАВЬ' -and $s.chat_id)
}

function Invoke-Tg($method, $body) {
    $s = Get-Secrets
    $json = ConvertTo-Json -InputObject $body -Depth 10 -Compress
    $r = Invoke-WebRequest -Uri "https://api.telegram.org/bot$($s.token)/$method" -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
        -UseBasicParsing -TimeoutSec 70
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
}

function Send-Tg($chatId, $text, $markup = $null) {
    # Telegram ограничивает сообщение 4096 символами — режем по строкам
    $chunks = @(); $cur = ''
    foreach ($line in ($text -split "`n")) {
        if (($cur.Length + $line.Length) -gt 3800) { $chunks += $cur; $cur = '' }
        $cur += "$line`n"
    }
    if ($cur.Trim()) { $chunks += $cur }
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $body = @{ chat_id = $chatId; text = $chunks[$i]; parse_mode = 'HTML'; disable_web_page_preview = $true }
        if ($markup -and $i -eq $chunks.Count - 1) { $body.reply_markup = $markup }   # кнопка — под последним куском
        try { Invoke-Tg 'sendMessage' $body | Out-Null }
        catch { Write-Log "Ошибка отправки в Telegram: $($_.Exception.Message)" }
    }
}

# Отчёт о поиске; с $appUrl — с кнопкой «Открыть приложение»
function Send-RunReport($newList, $appUrl, [switch]$SkipEmpty) {
    $newList = @($newList)
    $a = @($newList | Where-Object { $_.tier -eq 'A' }).Count
    $b = @($newList | Where-Object { $_.tier -eq 'B' }).Count
    $top = @($newList | Where-Object { $_.tier -in 'A', 'B' } | Sort-Object score -Descending)
    if ($SkipEmpty -and $top.Count -eq 0) { Write-Log 'Новых A/B нет — уведомление не отправляю'; return }
    $msg = "🗓 <b>Поиск вакансий</b>: новых $($newList.Count) (🟢 A: $a, 🟡 B: $b)`n`n"
    if ($top.Count) { $msg += Format-JobList $top 10 } else { $msg += 'Сильных новых вариантов нет.' }
    $markup = $null
    if ($appUrl) { $markup = @{ inline_keyboard = @(, @(@{ text = '📱 Открыть приложение'; web_app = @{ url = $appUrl } })) } }
    else { $msg += "`n/new — все новые · /top — лучшие за 2 недели" }
    Send-Tg (Get-Secrets).chat_id $msg $markup
}

function ConvertTo-TgSafe($s) { [System.Net.WebUtility]::HtmlEncode("$s") }

function Format-Job($j) {
    $icon = switch ($j.tier) { 'A' { '🟢' } 'B' { '🟡' } default { '⚪' } }
    $meta = @($j.location)
    if ($j.salary) { $meta += $j.salary }
    if ($j.exp) { $meta += $j.exp }
    if ($j.remote) { $meta += 'удалённо' }
    $out = "$icon <b>$(ConvertTo-TgSafe $j.title)</b> — $(ConvertTo-TgSafe $j.company)`n📍 $(ConvertTo-TgSafe ($meta -join ' · '))"
    if ($j.reasons) { $out += "`n✅ $(ConvertTo-TgSafe $j.reasons)" }
    if ($j.flags) { $out += "`n⚠️ $(ConvertTo-TgSafe $j.flags)" }
    $out + "`n<a href=`"$($j.url)`">Открыть вакансию</a>`n"
}

function Format-JobList($list, $max) {
    $list = @($list)
    if ($list.Count -eq 0) { return 'Ничего не найдено.' }
    $txt = ($list | Select-Object -First $max | ForEach-Object { Format-Job $_ }) -join "`n"
    if ($list.Count -gt $max) {
        $where = if ($env:APP_URL) { 'в приложении' } else { 'data/jobs.csv' }
        $txt += "`n…и ещё $($list.Count - $max). Полный список — $where"
    }
    $txt
}
