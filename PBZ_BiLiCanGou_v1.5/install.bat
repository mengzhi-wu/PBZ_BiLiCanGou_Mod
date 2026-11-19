@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title PBZ BiLiCanGou Mod Installer
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\PBZModSetup.ps1" %*
echo.
pause
