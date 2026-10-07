@echo off
rem Removes dcs-srs-play-audio for the current user. See README.md.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\uninstall.ps1" %*
pause
