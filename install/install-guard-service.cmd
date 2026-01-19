@echo off
REM ============================================================
REM VMGuard Guard Service - INSTALL
REM File: install-guard-service.cmd
REM Author: javaboy-vk
REM Version: 1.6
REM Date   : 2026-01-17
REM
REM PURPOSE:
REM   Installs or updates the VMGuard Guard as a Windows service
REM   using Apache Procrun (prunsrv.exe) AND enforces installation
REM   of the required user-context scheduled task used for smooth
REM   VM shutdown delegation.
REM
REM WHY THIS SCRIPT IS A .CMD (IMPORTANT):
REM   - Matches existing VMGuard operational tooling
REM   - Avoids PowerShell execution policy issues
REM   - Easy elevation (Run as Administrator)
REM   - Apache Procrun is designed to be driven from cmd.exe
REM
REM WHAT THIS SCRIPT DOES:
REM   1. Resolves VMGuard root dynamically
REM   2. Delegates ALL install logic to config-driven PowerShell installer
REM   3. Preserves CMD as elevation + entrypoint layer only
REM
REM v1.5 CHANGE:
REM   - Introduces central configuration model (\config\vmguard.config.json)
REM   - Removes all hard-coded paths and constants
REM   - Delegates all logic to install-guard-service.ps1
REM   - Enforces portability of entire VMGuard directory
REM ============================================================

setlocal ENABLEEXTENSIONS

set SCRIPT_DIR=%~dp0
REM install\ -> VMGuard\
set VMGUARD_ROOT=%SCRIPT_DIR%..

echo ===========================================
echo  VMGuard Guard Service INSTALL v1.6
echo  Root: %VMGUARD_ROOT%
echo ===========================================

powershell -NoProfile -ExecutionPolicy Bypass ^
  -File "%VMGUARD_ROOT%\install\install-guard-service.ps1"

set EXITCODE=%ERRORLEVEL%

if not "%EXITCODE%"=="0" (
    echo.
    echo [FATAL] Guard service installation failed. ExitCode=%EXITCODE%
    exit /b %EXITCODE%
)

echo.
echo [SUCCESS] VMGuard Guard Service installer completed successfully.
echo.

endlocal
exit /b 0
