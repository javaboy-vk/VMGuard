@echo off
REM ============================================================================
REM VMGuard – Install All (Host) – v1.2
REM File: install-all.cmd
REM Author: javaboy-vk
REM Date  : 2026-01-23
REM
REM PURPOSE
REM   Single-shot host installation of VMGuard components in dependency order,
REM   with post-step validation so "FATAL but exit 0" wrappers cannot mask failure.
REM
REM ORDER (HOST / HERCULES)
REM   1) Preshutdown Sentinel Service
REM   2) Guard Service
REM   3) Watcher Service
REM   4) Host Shutdown Interceptor (scheduled task)
REM
REM v1.2 CHANGE
REM   - Post-step validation:
REM       * Verifies services exist (sc query) and are RUNNING when required.
REM       * Verifies interceptor task exists (schtasks /query).
REM   - Uses Windows PowerShell explicit path.
REM   - Prefers *.ps1 installers when present to avoid broken wrapper quoting.
REM ============================================================================
setlocal EnableExtensions EnableDelayedExpansion

REM --- Admin check (best-effort) ---
net session >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Administrator privileges are required.
  echo         Right-click and "Run as administrator".
  exit /b 5
)

set "INSTALL_DIR=%~dp0"
for %%I in ("%INSTALL_DIR%\..") do set "VMG_ROOT=%%~fI"
if "%VMG_ROOT:~-1%"=="\" set "VMG_ROOT=%VMG_ROOT:~0,-1%"

set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
  echo [FATAL] Windows PowerShell not found: "%PSEXE%"
  exit /b 6
)

echo.
echo ===========================================
echo  VMGuard Install-All v1.2
echo ===========================================
echo Root       : "%VMG_ROOT%"
echo Install dir: "%INSTALL_DIR%"
echo.

call :RUN_STEP "Preshutdown Sentinel" ^
  "%INSTALL_DIR%install-preshutdown-sentinel-service.ps1" ^
  "%INSTALL_DIR%install-preshutdown-sentinel-service.cmd"
if errorlevel 1 exit /b 10
call :ASSERT_SERVICE_RUNNING "VMGuard-Preshutdown-Sentinel"
if errorlevel 1 exit /b 110

call :RUN_STEP "Guard Service" ^
  "%INSTALL_DIR%install-guard-service.ps1" ^
  "%INSTALL_DIR%install-guard-service.cmd"
if errorlevel 1 exit /b 11
call :ASSERT_SERVICE_RUNNING "VMGuard-Guard"
if errorlevel 1 exit /b 111

call :RUN_STEP "Watcher Service" ^
  "%INSTALL_DIR%install-watcher-service.ps1" ^
  "%INSTALL_DIR%install-watcher-service.cmd"
if errorlevel 1 exit /b 12
call :ASSERT_SERVICE_RUNNING "VMGuard-Watcher"
if errorlevel 1 exit /b 112

call :RUN_STEP "Host Shutdown Interceptor" ^
  "%INSTALL_DIR%install-vmguard-host-shutdown-interceptor.ps1" ^
  "%INSTALL_DIR%install-vmguard-host-shutdown-interceptor.cmd"
if errorlevel 1 exit /b 13
call :ASSERT_TASK_EXISTS "\Protepo\VMGuard-HostShutdown-Interceptor"
if errorlevel 1 exit /b 113

echo.
echo [PASS] VMGuard install-all completed successfully.
exit /b 0

:RUN_STEP
REM Args: 1=label 2=ps1path 3=cmdpath
set "LBL=%~1"
set "PS1=%~2"
set "CMD=%~3"

echo -------------------------------------------
echo [STEP] %LBL%
echo -------------------------------------------

if exist "%PS1%" (
  echo [INFO] Using PowerShell installer: "%PS1%"
  "%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
  exit /b %ERRORLEVEL%
)

if exist "%CMD%" (
  echo [INFO] Using CMD installer: "%CMD%"
  call "%CMD%"
  exit /b %ERRORLEVEL%
)

echo [FATAL] No installer found for step: %LBL%
exit /b 99

:ASSERT_SERVICE_RUNNING
set "SVC=%~1"
sc query "%SVC%" | findstr /I "STATE" >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Validation failed: service not queryable: %SVC%
  exit /b 1
)
sc query "%SVC%" | findstr /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Validation failed: service not RUNNING: %SVC%
  exit /b 1
)
echo [PASS] Validated service RUNNING: %SVC%
exit /b 0

:ASSERT_TASK_EXISTS
set "TN=%~1"
schtasks /query /tn "%TN%" >nul 2>&1
if errorlevel 1 (
  echo [FATAL] Validation failed: scheduled task missing: %TN%
  exit /b 1
)
echo [PASS] Validated scheduled task exists: %TN%
exit /b 0
