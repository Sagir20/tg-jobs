@echo off
chcp 65001 >nul
title Job search bot
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bot.ps1"
pause
