[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Stop-GitHubDesktopSafely {
    $processes = @(Get-Process -Name 'GitHubDesktop' -ErrorAction SilentlyContinue)
    if (-not $processes) { return }

    Write-Host 'Закрываю GitHub Desktop для безопасной замены файлов...'
    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            [void]$process.CloseMainWindow()
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(Get-Process -Name 'GitHubDesktop' -ErrorAction SilentlyContinue)
    } while ($remaining -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining) {
        $remaining | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }
}

function Get-OccurrenceCount {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Needle
    )

    $count = 0
    $offset = 0
    while (($offset = $Text.IndexOf($Needle, $offset, [StringComparison]::Ordinal)) -ge 0) {
        $count++
        $offset += $Needle.Length
    }
    return $count
}

function Invoke-FilePatch {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][object[]]$Operations
    )

    $text = [System.IO.File]::ReadAllText($FilePath)
    foreach ($operation in $Operations) {
        $needle = [string]$operation.needle
        $replacement = [string]$operation.replacement
        $expected = [int]$operation.occurrences
        $actual = Get-OccurrenceCount -Text $text -Needle $needle
        if ($actual -ne $expected) {
            throw "Структура файла не совпала с проверенной версией: ожидалось $expected совпадений, найдено $actual."
        }
        $text = $text.Replace($needle, $replacement)
    }

    [System.IO.File]::WriteAllText(
        $FilePath,
        $text,
        [System.Text.UTF8Encoding]::new($false)
    )
}

$patchRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $patchRoot 'patch-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Не найден файл патча: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$githubRoot = Join-Path $localAppData 'GitHubDesktop'
if (-not (Test-Path -LiteralPath $githubRoot)) {
    throw "GitHub Desktop не найден: $githubRoot"
}

$app = Get-Item -LiteralPath (Join-Path $githubRoot ([string]$manifest.supportedAppDirectory)) -ErrorAction SilentlyContinue
if ($null -eq $app) {
    $installed = @(Get-ChildItem -LiteralPath $githubRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -ExpandProperty Name)
    $installedText = if ($installed) { $installed -join ', ' } else { 'не найдены' }
    throw "Этот комплект рассчитан на $($manifest.supportedAppDirectory). Установленные версии: $installedText."
}

$exeFile = Join-Path $app.FullName 'GitHubDesktop.exe'
$targetAppDir = Join-Path $app.FullName 'resources\app'
$mainFile = Join-Path $targetAppDir 'main.js'
$rendererFile = Join-Path $targetAppDir 'renderer.js'
foreach ($required in @($exeFile, $mainFile, $rendererFile)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Не найден файл GitHub Desktop: $required"
    }
}

$statePath = Join-Path $githubRoot 'ru-locale-patch.json'
if (Test-Path -LiteralPath $statePath) {
    $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mainHash = (Get-FileHash -LiteralPath $mainFile -Algorithm SHA256).Hash
    $rendererHash = (Get-FileHash -LiteralPath $rendererFile -Algorithm SHA256).Hash
    if (
        [string]$existingState.patchVersion -eq [string]$manifest.patchVersion -and
        $mainHash -eq [string]$manifest.patchedSha256.main -and
        $rendererHash -eq [string]$manifest.patchedSha256.renderer
    ) {
        Write-Host "Русский патч $($manifest.patchVersion) уже установлен."
        if (-not $NoLaunch) { Start-Process -FilePath $exeFile }
        return
    }
    throw 'Найден другой установленный русский патч. Сначала запусти «Вернуть-английский.cmd», затем повтори установку.'
}

$currentMainHash = (Get-FileHash -LiteralPath $mainFile -Algorithm SHA256).Hash
$currentRendererHash = (Get-FileHash -LiteralPath $rendererFile -Algorithm SHA256).Hash
if (
    $currentMainHash -ne [string]$manifest.originalSha256.main -or
    $currentRendererHash -ne [string]$manifest.originalSha256.renderer
) {
    throw 'Файлы GitHub Desktop отличаются от проверенной оригинальной версии. Установка остановлена без изменений.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $githubRoot 'ru-locale-backups'
$backupDir = Join-Path (Join-Path $backupRoot $app.Name) $timestamp
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "GitHubDesktopRuPatch-$timestamp-$PID"
$stageAppDir = Join-Path $stageRoot 'app'

Write-Host "Версия GitHub Desktop: $($app.Name)"
Write-Host "Версия русского патча: $($manifest.patchVersion)"
Stop-GitHubDesktopSafely

New-Item -ItemType Directory -Path $stageAppDir -Force | Out-Null
Copy-Item -LiteralPath $mainFile -Destination (Join-Path $stageAppDir 'main.js')
Copy-Item -LiteralPath $rendererFile -Destination (Join-Path $stageAppDir 'renderer.js')

try {
    Invoke-FilePatch -FilePath (Join-Path $stageAppDir 'main.js') -Operations @($manifest.operations.main)
    Invoke-FilePatch -FilePath (Join-Path $stageAppDir 'renderer.js') -Operations @($manifest.operations.renderer)

    $stagedMainHash = (Get-FileHash -LiteralPath (Join-Path $stageAppDir 'main.js') -Algorithm SHA256).Hash
    $stagedRendererHash = (Get-FileHash -LiteralPath (Join-Path $stageAppDir 'renderer.js') -Algorithm SHA256).Hash
    if (
        $stagedMainHash -ne [string]$manifest.patchedSha256.main -or
        $stagedRendererHash -ne [string]$manifest.patchedSha256.renderer
    ) {
        throw 'Контрольные суммы подготовленных файлов не совпали с эталоном. Установка остановлена.'
    }

    $appliedKeys = @($manifest.operations.main).Count + @($manifest.operations.renderer).Count
    $appliedOccurrences = 0
    foreach ($operation in @($manifest.operations.main) + @($manifest.operations.renderer)) {
        $appliedOccurrences += [int]$operation.occurrences
    }
    Write-Host "Переведено ключей: $appliedKeys"
    Write-Host "Выполнено замен: $appliedOccurrences"

    if ($DryRun) {
        Write-Host 'Тест завершён: установленные файлы не изменялись.'
        return
    }

    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Copy-Item -LiteralPath $mainFile -Destination (Join-Path $backupDir 'main.js')
    Copy-Item -LiteralPath $rendererFile -Destination (Join-Path $backupDir 'renderer.js')
    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backupDir 'patch-manifest.json')

    Copy-Item -LiteralPath (Join-Path $stageAppDir 'main.js') -Destination $mainFile -Force
    Copy-Item -LiteralPath (Join-Path $stageAppDir 'renderer.js') -Destination $rendererFile -Force

    $state = [ordered]@{
        patchVersion = [string]$manifest.patchVersion
        installedAt = (Get-Date).ToString('o')
        appVersionDirectory = $app.Name
        targetAppDir = $targetAppDir
        backupDir = $backupDir
        originalSha256 = $manifest.originalSha256
        patchedSha256 = $manifest.patchedSha256
        appliedKeys = $appliedKeys
        appliedOccurrences = $appliedOccurrences
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-Host "Резервная копия: $backupDir"
    Write-Host 'Русская локализация установлена.'

    if (-not $NoLaunch) {
        Start-Process -FilePath $exeFile
    }
}
catch {
    if (-not $DryRun -and (Test-Path -LiteralPath (Join-Path $backupDir 'main.js'))) {
        Write-Warning 'Установка не завершена. Восстанавливаю исходные файлы.'
        Copy-Item -LiteralPath (Join-Path $backupDir 'main.js') -Destination $mainFile -Force
        Copy-Item -LiteralPath (Join-Path $backupDir 'renderer.js') -Destination $rendererFile -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        $resolvedStage = [System.IO.Path]::GetFullPath($stageRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedStage.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
            [System.IO.Directory]::Delete($resolvedStage, $true)
        }
    }
}
