@echo off
REM ============================================================================
REM VMGuard – Developer Harness Launcher – v1.2
REM File: vmguard-dev-menu.cmd
REM Author: javaboy-vk
REM Date  : 2026-01-23
REM
REM PURPOSE:
REM   Portable launcher for the VMGuard developer harness.
REM   - Anchors execution to this script's directory (no hard-coded drives)
REM   - Launches PowerShell with process-scoped ExecutionPolicy Bypass
REM   - Invokes vmguard-dev-menu.ps1 (same folder)
REM
REM NOTE:
REM   If you see: [FATAL] Unable to resolve VMGuard root from script location,
REM   you are running an older dev-menu.ps1. Replace it with v1.13+.
REM ============================================================================

setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%vmguard-dev-menu.ps1"

if not exist "%PS1%" (
  echo [FATAL] Missing: "%PS1%"
  exit /b 2
)

pushd "%SCRIPT_DIR%" >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Unable to set working directory to: "%SCRIPT_DIR%"
  exit /b 3
)

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PSEXE%" (
  "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
) else (
  where pwsh >nul 2>&1
  if errorlevel 1 (
    echo [FATAL] Neither Windows PowerShell nor pwsh was found on PATH.
    popd >nul 2>&1
    exit /b 4
  )
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
)

set "RC=%ERRORLEVEL%"
popd >nul 2>&1
exit /b %RC%
