@echo off
REM ================================================================================
REM  VMGuard – Host Shutdown Interceptor Installer – v1.4
REM ================================================================================
REM  Script Name : install-vmguard-host-shutdown-interceptor.cmd
REM  Author      : javaboy-vk
REM  Date        : 2026-01-14
REM  Version     : 1.4
REM
REM  PURPOSE
REM    Install the VMGuard Host Shutdown Interceptor scheduled task using a full
REM    XML task definition. The task identity and folder are owned by the XML
REM    contract (URI = \Protepo\VMGuard-HostShutdown-Interceptor).
REM
REM  RESPONSIBILITIES
REM    - Remove any existing interceptor task (best effort)
REM    - Install scheduled task from XML definition
REM    - Ensure clean, deterministic OS-level wiring
REM
REM  NON-RESPONSIBILITIES
REM    - Does NOT start/stop VMGuard services
REM    - Does NOT validate VMware configuration
REM
REM  CHANGELOG
REM    v1.1 – Fixed CMD header format
REM    v1.2 – Switched to XML-based task installation
REM    v1.3 – XML owns identity and folder via <URI>
REM    v1.4 – Added mandatory /TN and hardened error handling
REM ================================================================================
setlocal enabledelayedexpansion

set "TASK_NAME=\Protepo\VMGuard-HostShutdown-Interceptor"
set "TASK_XML=P:\Scripts\VMGuard\install\vmguard-host-shutdown-interceptor-task.xml"

echo ===========================================
echo VMGuard Host Shutdown Interceptor Installer v1.4
echo ===========================================
echo Task URI : %TASK_NAME%
echo Task XML : %TASK_XML%
echo.

if not exist "%TASK_XML%" (
  echo [FAIL] Missing task XML:
  echo        %TASK_XML%
  echo        Install aborted.
  exit /b 1
)

echo [INFO] Removing existing task if present...
schtasks /Delete /TN "%TASK_NAME%" /F >nul 2>&1

echo [INFO] Creating scheduled task from XML contract...
schtasks /Create ^
  /TN "%TASK_NAME%" ^
  /XML "%TASK_XML%" ^
  /F

if errorlevel 1 (
  echo [FAIL] Task creation failed.
  echo        Verify XML and run from an elevated Admin console.
  exit /b 1
)

echo [PASS] Host Shutdown Interceptor installed.
echo [INFO] Verifying task registration...
schtasks /Query /TN "%TASK_NAME%" /V /FO LIST

if errorlevel 1 (
  echo [FAIL] Task verification failed.
  exit /b 1
)

echo.
echo [DONE] Installation complete.
exit /b 0
