@echo off
chcp 65001 >nul
title Восстановление GitHub Desktop 3.6.4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-Russian.ps1"
echo.
if errorlevel 1 (
  echo Восстановление не выполнено. Текст ошибки указан выше.
) else (
  echo Готово. Окно можно закрыть.
)
pause
