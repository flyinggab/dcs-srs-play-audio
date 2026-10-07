@echo off
rem Installs dcs-srs-play-audio for the current user. See README.md.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\install.ps1" %*
pause
