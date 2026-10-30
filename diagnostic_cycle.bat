@echo off
setlocal
cd /d "%~dp0"
rem One pass: git fast-forward, Release build, timed OpenXR capture sweep,
rem then upload this run's PNGs and logs to diagnostics/runs in dev.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\DiagnosticCycle.ps1" %*
exit /b %errorlevel%
