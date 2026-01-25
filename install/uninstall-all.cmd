@echo off
REM ============================================================================
REM VMGuard - Uninstall All (Host) - v1.5
REM File: uninstall-all.cmd
REM Author: javaboy-vk
REM Date  : 2026-01-23
REM
REM PURPOSE
REM   Single-shot host uninstallation of VMGuard components in reverse order,
REM   with post-step validation so "FATAL but exit 0" wrappers cannot mask failure.
REM ============================================================================
setlocal EnableExtensions

net session >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Administrator privileges are required.
  exit /b 5
)

set "INSTALL_DIR=%~dp0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
  echo [FATAL] Windows PowerShell not found: "%PSEXE%"
  exit /b 6
)

echo.
echo ===========================================
echo  VMGuard Uninstall-All v1.5
echo ===========================================
echo Install dir: "%INSTALL_DIR%"
echo.

call :RUN_STEP "Host Shutdown Interceptor" "%INSTALL_DIR%uninstall-vmguard-host-shutdown-interceptor.ps1" "%INSTALL_DIR%uninstall-vmguard-host-shutdown-interceptor.cmd"
call :ASSERT_TASK_MISSING "\Protepo\VMGuard-HostShutdown-Interceptor"
if errorlevel 1 exit /b 120

call :RUN_STEP "Watcher Service" "%INSTALL_DIR%uninstall-watcher-service.ps1" "%INSTALL_DIR%uninstall-watcher-service.cmd"
call :ASSERT_SERVICE_MISSING "VMGuard-Watcher"
if errorlevel 1 exit /b 121

call :RUN_STEP "Guard Service" "%INSTALL_DIR%uninstall-guard-service.ps1" "%INSTALL_DIR%uninstall-guard-service.cmd"
call :ASSERT_SERVICE_MISSING "VMGuard-Guard"
if errorlevel 1 exit /b 122
call :ASSERT_TASK_MISSING "\Protepo\VMGuard-Guard-User"
if errorlevel 1 exit /b 124
call :ASSERT_TASK_MISSING "\Protepo\VMGuard\VMGuard-User-Shutdown-Delegate"
if errorlevel 1 exit /b 125

call :RUN_STEP "Preshutdown Sentinel" "%INSTALL_DIR%uninstall-preshutdown-sentinel-service.ps1" "%INSTALL_DIR%uninstall-preshutdown-sentinel-service.cmd"
call :ASSERT_SERVICE_MISSING "VMGuard-Preshutdown-Sentinel"
if errorlevel 1 exit /b 123

echo.
echo [PASS] VMGuard uninstall-all completed successfully.
exit /b 0

:RUN_STEP
set "LBL=%~1"
set "PS1=%~2"
set "CMD=%~3"

echo -------------------------------------------
echo [STEP] %LBL%
echo -------------------------------------------

if exist "%PS1%" (
  echo [INFO] Using PowerShell uninstaller: "%PS1%"
  "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
  exit /b %ERRORLEVEL%
)

if exist "%CMD%" (
  echo [INFO] Using CMD uninstaller: "%CMD%"
  call "%CMD%"
  exit /b %ERRORLEVEL%
)

echo [WARN] No uninstaller found for step: %LBL% (continuing)
exit /b 0

:ASSERT_SERVICE_MISSING
set "SVC=%~1"
sc query "%SVC%" >nul 2>&1
if errorlevel 0 (
  echo [FATAL] Validation failed: service still present: %SVC%
  exit /b 1
)
echo [PASS] Validated service removed: %SVC%
exit /b 0

:ASSERT_TASK_MISSING
set "TN=%~1"
schtasks /query /tn "%TN%" >nul 2>&1
if errorlevel 0 (
  echo [FATAL] Validation failed: task still present: %TN%
  exit /b 1
)
echo [PASS] Validated task removed: %TN%
exit /b 0
