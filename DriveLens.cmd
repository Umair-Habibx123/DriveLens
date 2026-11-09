@echo off
title DriveLens
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DriveLens.ps1"
if errorlevel 1 (
  echo.
  echo The scan did not finish. See the message above.
  pause
)
