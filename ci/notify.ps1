#requires -Version 7.0
# После публикации сайта: прописать кнопку «Вакансии» в меню бота и прислать отчёт о новых вакансиях.
param([string]$PageUrl = $env:APP_URL)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
. (Join-Path $Root 'lib.ps1')

if (-not (Test-TelegramReady)) { Write-Log 'Нет TG_TOKEN / TG_CHAT_ID — уведомление пропускаю'; exit 0 }
$s = Get-Secrets

$appUrl = $null
if ($PageUrl) {
    # Ключ расшифровки передаётся в адресе: он есть только в кнопках твоего чата с ботом
    $appUrl = $PageUrl.TrimEnd('/') + '/?k=' + $env:DATA_KEY.Trim()
    $env:APP_URL = $appUrl
    $r = Invoke-Tg 'setChatMenuButton' @{ chat_id = $s.chat_id; menu_button = @{ type = 'web_app'; text = 'Вакансии'; web_app = @{ url = $appUrl } } }
    Write-Log "Кнопка меню: $($r.ok)"
}

$last = Read-JsonFile (Join-Path $DataDir 'last_run.json')
$jobs = Get-Jobs
$list = @($last.keys | ForEach-Object { $jobs[$_] } | Where-Object { $_ })
Send-RunReport $list $appUrl -SkipEmpty
