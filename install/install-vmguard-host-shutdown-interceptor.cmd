@echo off
REM ================================================================================
REM  VMGuard – Host Shutdown Interceptor Installer (CMD Wrapper) – v1.8
REM ================================================================================
REM  Script Name : install-vmguard-host-shutdown-interceptor.cmd
REM  Author      : javaboy-vk
REM  Date        : 2026-01-19
REM  Version     : 1.8
REM
REM  PURPOSE
REM    CMD wrapper to invoke the canonical PowerShell installer:
REM      install\install-vmguard-host-shutdown-interceptor.ps1
REM
REM  WHY CMD
REM    - Matches VMGuard operational tooling conventions
REM    - Easy elevation (Run as Administrator)
REM    - Avoids PS execution policy surprises for operators
REM
REM  PORTABILITY
REM    - No hard-coded drive paths
REM    - VMGuard root is derived from this script location (install\ -> VMGuard\)
REM ================================================================================

setlocal ENABLEEXTENSIONS

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "INSTALLER_PS1=%SCRIPT_DIR%\install-vmguard-host-shutdown-interceptor.ps1"
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

echo ===========================================
echo VMGuard Host Shutdown Interceptor Installer (Wrapper) v1.8
echo ===========================================
echo Installer PS1: %INSTALLER_PS1%
echo.

if not exist "%INSTALLER_PS1%" (
  echo [FATAL] Missing PowerShell installer:
  echo         %INSTALLER_PS1%
  exit /b 1
)

"%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER_PS1%"
exit /b %ERRORLEVEL%
