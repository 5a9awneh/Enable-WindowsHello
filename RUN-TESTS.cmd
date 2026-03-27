@echo off
title Enable-WindowsHello Test Runner
cd /d "%~dp0"

if /i "%~1"=="live" (
    echo Running LIVE tests (Status mode on real system, requires Admin)...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester '%~dp0Enable-WindowsHello.Tests.ps1' -Tag 'Live' -Output Detailed"
) else if /i "%~1"=="all" (
    echo Running ALL tests (mock + live)...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester '%~dp0Enable-WindowsHello.Tests.ps1' -Output Detailed"
) else (
    echo Running mock tests (excluding Live)...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester '%~dp0Enable-WindowsHello.Tests.ps1' -ExcludeTag 'Live' -Output Detailed"
)

echo.
pause
