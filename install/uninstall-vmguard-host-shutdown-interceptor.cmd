@echo off
REM ================================================================================
REM  VMGuard – Host Shutdown Interceptor Uninstaller – v1.2
REM ================================================================================
REM  Script Name : uninstall-vmguard-host-shutdown-interceptor.cmd
REM  Author      : javaboy-vk
REM  Date        : 2026-01-14
REM  Version     : 1.2
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
REM    v1.1 – Converted header to CMD-compliant format
REM    v1.2 – Fixed IF/ELSE block parsing issue (removed raw parentheses)
REM ================================================================================
setlocal enabledelayedexpansion

set "TASK_NAME=VMGuard-HostShutdown-Interceptor"

echo ===========================================
echo VMGuard Host Shutdown Interceptor Uninstaller v1.2
echo ===========================================
echo Task Name : %TASK_NAME%
echo.

echo [INFO] Deleting scheduled task (best effort)...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

if errorlevel 1 (
  echo [WARN] Task deletion returned non-zero. Task may not exist or access denied.
  echo        Continuing.
) else (
  echo [PASS] Task deleted or task did not exist: %TASK_NAME%
)

echo.
echo [INFO] Verifying task is absent...
schtasks /Query /TN "%TASK_NAME%" >nul 2>&1

if errorlevel 0 (
  echo [FAIL] Task still present: %TASK_NAME%
  echo        Open an elevated Admin console and retry.
  exit /b 1
)

echo [PASS] Task not present: %TASK_NAME%
echo.
echo [DONE] Uninstall complete.
exit /b 0
