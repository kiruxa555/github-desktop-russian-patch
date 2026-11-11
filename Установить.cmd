@echo off
chcp 65001 >nul
title Русификатор GitHub Desktop 3.6.4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Russian.ps1"
echo.
if errorlevel 1 (
  echo Установка не выполнена. Текст ошибки указан выше.
) else (
  echo Готово. Окно можно закрыть.
)
pause
