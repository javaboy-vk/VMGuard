@echo off
setlocal EnableExtensions

REM ==============================================================================
REM  VMGuard – Watcher Service Uninstall Script (Wrapper) – v1.6
REM ==============================================================================
REM
REM  AUTHOR
REM  ------
REM  javaboy-vk
REM  Version: 1.6
REM  Date   : 2026-01-23
REM
REM  PURPOSE
REM  -------
REM  Wrapper entrypoint for watcher uninstall. Delegates all uninstall logic to:
REM    uninstall-watcher-service.ps1
REM
REM  PORTABILITY
REM  ----------
REM  - Anchored to this script directory
REM  - No hard-coded drive letters
REM
REM  NOTE
REM  ----
REM  This wrapper intentionally avoids PowerShell one-liner quoting patterns that
REM  can corrupt command parsing (e.g., embedded "try { ... }").
REM ==============================================================================

set "SCRIPT_DIR=%~dp0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%SCRIPT_DIR%uninstall-watcher-service.ps1"

if not exist "%PS1%" (
  echo [FATAL] Missing: "%PS1%"
  exit /b 2
)

if not exist "%PSEXE%" (
  echo [FATAL] Windows PowerShell not found: "%PSEXE%"
  exit /b 3
)

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
