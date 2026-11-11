[CmdletBinding()]
param(
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$githubRoot = Join-Path $localAppData 'GitHubDesktop'
$backupRoot = Join-Path $githubRoot 'ru-locale-backups'
$statePath = Join-Path $githubRoot 'ru-locale-patch.json'

if (-not (Test-Path -LiteralPath $statePath)) {
    throw 'Сведения об установленном русском патче не найдены.'
}

$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetAppDir = [System.IO.Path]::GetFullPath([string]$state.targetAppDir)
$backupDir = [System.IO.Path]::GetFullPath([string]$state.backupDir)
$resolvedGitHubRoot = [System.IO.Path]::GetFullPath($githubRoot)
$resolvedBackupRoot = [System.IO.Path]::GetFullPath($backupRoot)

if (-not $targetAppDir.StartsWith($resolvedGitHubRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Небезопасный целевой путь в состоянии патча: $targetAppDir"
}
if (-not $backupDir.StartsWith($resolvedBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Небезопасный путь резервной копии: $backupDir"
}

$backupMain = Join-Path $backupDir 'main.js'
$backupRenderer = Join-Path $backupDir 'renderer.js'
if (-not (Test-Path -LiteralPath $backupMain) -or -not (Test-Path -LiteralPath $backupRenderer)) {
    throw "Резервная копия неполна: $backupDir"
}

$processes = @(Get-Process -Name 'GitHubDesktop' -ErrorAction SilentlyContinue)
foreach ($process in $processes) {
    if ($process.MainWindowHandle -ne 0) { [void]$process.CloseMainWindow() }
}
if ($processes) { Start-Sleep -Seconds 2 }
$remaining = @(Get-Process -Name 'GitHubDesktop' -ErrorAction SilentlyContinue)
if ($remaining) { $remaining | Stop-Process -Force }

Copy-Item -LiteralPath $backupMain -Destination (Join-Path $targetAppDir 'main.js') -Force
Copy-Item -LiteralPath $backupRenderer -Destination (Join-Path $targetAppDir 'renderer.js') -Force

$restoredMainHash = (Get-FileHash -LiteralPath (Join-Path $targetAppDir 'main.js') -Algorithm SHA256).Hash
$restoredRendererHash = (Get-FileHash -LiteralPath (Join-Path $targetAppDir 'renderer.js') -Algorithm SHA256).Hash
if ($restoredMainHash -ne [string]$state.originalSha256.main -or
    $restoredRendererHash -ne [string]$state.originalSha256.renderer) {
    throw 'Контрольные суммы восстановленных файлов не совпали с оригиналом.'
}

Remove-Item -LiteralPath $statePath -Force
Write-Host 'Оригинальный английский интерфейс GitHub Desktop восстановлен.'
Write-Host "Резервная копия сохранена: $backupDir"

if (-not $NoLaunch) {
    $exePath = Join-Path (Split-Path -Parent (Split-Path -Parent $targetAppDir)) 'GitHubDesktop.exe'
    if (Test-Path -LiteralPath $exePath) {
        Start-Process -FilePath $exePath
    }
}
