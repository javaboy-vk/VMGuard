@echo off
REM ================================================================================
REM  VMGuard ??? Host Shutdown Interceptor Uninstaller ??? v1.7
REM ================================================================================
REM  Script Name : uninstall-vmguard-host-shutdown-interceptor.cmd
REM  Author      : javaboy-vk
REM  Date        : 2026-01-14
REM  Version     : 1.7
REM
REM  PURPOSE
REM    Remove the VMGuard Host Shutdown Interceptor scheduled task.
REM
REM  RESPONSIBILITIES
REM    - Delete the scheduled task (best effort)
REM    - Provide clear console output and safe exit behavior
REM
REM  NON-RESPONSIBILITIES
REM    - Does NOT remove VMGuard scripts
REM    - Does NOT stop/start VMGuard services
REM
REM  CHANGELOG
REM    v1.1 ??? Converted header to CMD-compliant format
REM    v1.2 ??? Fixed IF/ELSE block parsing issue (removed raw parentheses)
REM    v1.3 ??? Target full task path and echo schtasks delete command
REM    v1.4 ??? Require admin and show schtasks error output on failure
REM    v1.5 ??? Try multiple task path variants and emit task discovery hints
REM    v1.7 ??? Remove alternate/legacy task paths (single canonical task only)
REM ================================================================================
setlocal EnableExtensions

REM --- Admin check (best-effort) ---
net session >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Administrator privileges are required.
  echo         Right-click and "Run as administrator".
  exit /b 5
)

set "TASK_NAME=\Protepo\VMGuard-HostShutdown-Interceptor"

REM Resolve root for log-safe temp output (must stay under VMGuard\logs)
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "VMGUARD_ROOT=%%~fI"
set "LOG_DIR=%VMGUARD_ROOT%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "SCHTASKS_OUT=%LOG_DIR%\vmguard-schtasks-delete.tmp"

echo ===========================================
echo VMGuard Host Shutdown Interceptor Uninstaller v1.7
echo ===========================================
echo Task Name : %TASK_NAME%
echo.

call :DELETE_TASK "%TASK_NAME%"

echo.
echo [INFO] Verifying task is absent...
set "PRESENT=0"
call :CHECK_TASK "%TASK_NAME%"

if "%PRESENT%"=="1" (
  echo [FAIL] Task still present under one of the known paths.
  echo        Open an elevated Admin console and retry.
  echo          exit /b 1
)

echo [PASS] Task not present: %TASK_NAME%
echo.
echo [DONE] Uninstall complete.
exit /b 0

:DELETE_TASK
set "TN=%~1"
if "%TN%"=="" exit /b 0
echo [INFO] Deleting scheduled task (best effort)...
echo        schtasks /Delete /TN "%TN%" /F
schtasks /Delete /TN "%TN%" /F > "%SCHTASKS_OUT%" 2>&1
if errorlevel 1 (
  echo [WARN] Task deletion returned non-zero. Task may not exist or access denied.
  call :ECHO_FILE "%SCHTASKS_OUT%"
  echo        Continuing.
) else (
  echo [PASS] Task deleted or task did not exist: %TN%
)
if exist "%SCHTASKS_OUT%" del "%SCHTASKS_OUT%" >nul 2>&1
exit /b 0

:ECHO_FILE
set "FILE=%~1"
if exist "%FILE%" (
  for /f "usebackq delims=" %%L in ("%FILE%") do echo        %%L
)
exit /b 0

:CHECK_TASK
set "TN=%~1"
if "%TN%"=="" exit /b 0
schtasks /Query /TN "%TN%" >nul 2>&1
if errorlevel 0 set "PRESENT=1"
exit /b 0







