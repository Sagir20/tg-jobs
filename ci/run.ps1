#requires -Version 7.0
# Запускается в GitHub Actions:
#   расшифровать базу → поиск → почистить базу → зашифровать базу и данные для Mini App.
# База и данные приложения шифруются AES-256-GCM ключом из секрета DATA_KEY,
# поэтому в публичном репозитории и на GitHub Pages лежит только шифротекст.
param(
    [string]$Store = 'store.enc',      # зашифрованная база из ветки db (если есть)
    [string]$OutDb = 'out/jobs.enc',   # куда положить новую зашифрованную базу
    [string]$Site  = 'site',           # папка сайта для GitHub Pages
    [int]$KeepDays = 90                # сколько дней хранить вакансии
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'lib.ps1')

function ConvertFrom-B64Url([string]$s) {
    $s = $s.Trim().Replace('-', '+').Replace('_', '/')
    while ($s.Length % 4) { $s += '=' }
    [Convert]::FromBase64String($s)
}

if (-not $env:DATA_KEY) { throw 'Нет секрета DATA_KEY (Settings → Secrets and variables → Actions)' }
$Key = ConvertFrom-B64Url $env:DATA_KEY
if ($Key.Length -ne 32) { throw "DATA_KEY должен быть 32 байта, а не $($Key.Length)" }

# Формат: nonce(12) | шифротекст | tag(16) — так же читает WebCrypto в браузере
function Protect-Bytes([byte[]]$plain) {
    $iv = [byte[]]::new(12); [Security.Cryptography.RandomNumberGenerator]::Fill($iv)
    $ct = [byte[]]::new($plain.Length); $tag = [byte[]]::new(16)
    $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Encrypt($iv, $plain, $ct, $tag) } finally { $aes.Dispose() }
    $ms = [IO.MemoryStream]::new()
    $ms.Write($iv, 0, 12); $ms.Write($ct, 0, $ct.Length); $ms.Write($tag, 0, 16)
    $ms.ToArray()
}

function Unprotect-Bytes([byte[]]$blob) {
    $n = $blob.Length - 28
    $iv = [byte[]]::new(12); $ct = [byte[]]::new($n); $tag = [byte[]]::new(16)
    [Array]::Copy($blob, 0, $iv, 0, 12)
    [Array]::Copy($blob, 12, $ct, 0, $n)
    [Array]::Copy($blob, 12 + $n, $tag, 0, 16)
    $plain = [byte[]]::new($n)
    $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
    try { $aes.Decrypt($iv, $ct, $tag, $plain) } finally { $aes.Dispose() }
    $plain
}

function Compress-Bytes([byte[]]$b) {
    $ms = [IO.MemoryStream]::new()
    $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionLevel]::Optimal)
    $gz.Write($b, 0, $b.Length); $gz.Dispose()
    $ms.ToArray()
}

function Expand-Bytes([byte[]]$b) {
    $gz = [IO.Compression.GZipStream]::new([IO.MemoryStream]::new($b), [IO.Compression.CompressionMode]::Decompress)
    $out = [IO.MemoryStream]::new()
    $gz.CopyTo($out); $gz.Dispose()
    $out.ToArray()
}

# 1. База из прошлого запуска
$dbPath = Join-Path $DataDir 'jobs.json'
$days = 0
$restored = $false
if ((Test-Path $Store) -and (Get-Item $Store).Length -gt 28) {
    try {
        [IO.File]::WriteAllBytes($dbPath, (Expand-Bytes (Unprotect-Bytes ([IO.File]::ReadAllBytes((Resolve-Path $Store))))))
        Write-Log "База восстановлена: $(@((Get-Jobs).Values).Count) вакансий"
        $restored = $true
    } catch { Write-Log 'Базу не удалось расшифровать (сменился DATA_KEY?) — начинаю заново' }
}
if (-not $restored) {
    $days = 30   # первый запуск — берём вакансии за месяц
    Write-Log 'Базы нет — первый запуск, ищу за 30 дней'
}

# 2. Поиск (уведомление отправит notify.ps1 после публикации сайта)
& (Join-Path $Root 'search.ps1') -NoNotify -Days $days
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "search.ps1 завершился с кодом $LASTEXITCODE" }

# 2б. Дочитать описания вакансий, оценённых только по названию, и пересчитать оценки
& (Join-Path $Root 'search.ps1') -Rescore -MaxDetails 250

# 3. Чистка: старые вакансии удаляем, тексты укорачиваем
$jobs = Get-Jobs
$cut = (Get-Date).AddDays(-$KeepDays).ToString('yyyy-MM-dd HH:mm')
foreach ($k in @($jobs.Keys)) {
    $j = $jobs[$k]
    if ("$($j.found)" -lt $cut) { $jobs.Remove($k); continue }
    if ("$($j.text)".Length -gt 2000) { $j.text = "$($j.text)".Substring(0, 2000) }
}
Save-Jobs $jobs
Write-Log "В базе после чистки: $($jobs.Count)"

# 4. Зашифрованная база → ветка db
New-Item -ItemType Directory -Force (Split-Path $OutDb -Parent) | Out-Null
[IO.File]::WriteAllBytes((Join-Path (Get-Location) $OutDb), (Protect-Bytes (Compress-Bytes ([IO.File]::ReadAllBytes($dbPath)))))

# 5. Сайт: страница приложения + зашифрованные данные
New-Item -ItemType Directory -Force $Site | Out-Null
Copy-Item (Join-Path $Root 'app/index.html') (Join-Path $Site 'index.html') -Force
Set-Content (Join-Path $Site '.nojekyll') ''
$appJson = ConvertTo-Json -InputObject (Get-AppData $jobs) -Depth 5 -Compress
[IO.File]::WriteAllBytes((Join-Path (Resolve-Path $Site) 'data.bin'), (Protect-Bytes ([Text.Encoding]::UTF8.GetBytes($appJson))))
Write-Log "Сайт собран: $($jobs.Count) вакансий, data.bin $([int]((Get-Item (Join-Path $Site 'data.bin')).Length / 1KB)) КБ"
