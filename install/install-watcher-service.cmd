@echo off
REM ============================================================
REM VMGuard Watcher Service - INSTALL (Wrapper)
REM File: install\install-watcher-service.cmd
REM Author: javaboy-vk
REM Version: 3.3
REM Date   : 2026-01-23
REM
REM PURPOSE:
REM   CMD is the elevation-friendly entrypoint only.
REM   All service install/update logic runs in PowerShell.
REM
REM PORTABILITY:
REM   - Anchored to this script directory
REM   - No hard-coded drive letters
REM
REM HARD RULE:
REM   STOP semantics are implemented by the Watcher service itself.
REM   This wrapper must never obstruct STOP or lifecycle determinism.
REM ============================================================

setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS1=%SCRIPT_DIR%install-watcher-service.ps1"

if not exist "%PS1%" (
  echo [FATAL] Missing: "%PS1%"
  exit /b 2
)

if not exist "%PSEXE%" (
  echo [FATAL] Windows PowerShell not found: "%PSEXE%"
  exit /b 3
)

REM Call PowerShell installer (no fragile one-liner quoting)
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
