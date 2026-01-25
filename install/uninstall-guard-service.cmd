@echo off
setlocal ENABLEEXTENSIONS

REM ============================================================
REM VMGuard Guard Service - UNINSTALL
REM File: uninstall-guard-service.cmd
REM Author: javaboy-vk
REM Version: 2.6
REM Date   : 2026-01-23
REM
REM PURPOSE:
REM   Cleanly uninstalls the VMGuard Guard Windows service.
REM
REM   It strictly follows the Windows service lifecycle:
REM     1. Request STOP
REM     2. Wait until STATE = STOPPED
REM     3. Only then delete the service via Procrun
REM
REM PORTABILITY CONTRACT:
REM   - No hard-coded drive letters
REM   - VMGuard root is derived from this script location:
REM       VMGuard\install\uninstall-guard-service.cmd  ->  VMGuard\
REM   - Service identity is read from conf\settings.json:
REM       services.guard.name
REM   - Logs directory is read from conf\settings.json:
REM       paths.logs (relative to VMGuard root)
REM
REM CHANGELOG
REM   v1.2   – Portable root resolution + config-driven service name
REM   v1.2.1 – Fixes CMD quoting failure by using a single-line PowerShell -Command
REM   v2.0   – Eliminates install\generated\guard-uninstall-env.cmd creation.
REM            Values are streamed directly from PowerShell into CMD variables.
REM   v2.1   – Fixes CMD parser error ") was unexpected at this time" by simplifying
REM            PowerShell extraction (no nested FOR blocks, no caret-escaped multiline).
REM            Also hardens stop-duration logging line to avoid redirection token issues.
REM   v2.2   – Removes delayed expansion (prevents !-expansion hazards).
REM   v2.3   – Attempts to harden PowerShell extraction (cmd meta parsing issues remained).
REM   v2.4   – FIX: Make FOR /F PowerShell calls single-line and unquoted exe path
REM            (no multiline, no backticks/usebackq). Eliminates leading "'" failure.
REM ============================================================

REM ==================================================================
REM SECTION 0 — VMGUARD ROOT RESOLUTION (INSTALL\ -> VMGUARD\)
REM ==================================================================

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

for %%I in ("%SCRIPT_DIR%\..") do set "VMGUARD_ROOT=%%~fI"

REM ==================================================================
REM SECTION 1 — CANONICAL SETTINGS.JSON
REM ==================================================================

set "SETTINGS_JSON=%VMGUARD_ROOT%\conf\settings.json"

if not exist "%SETTINGS_JSON%" (
    echo [FATAL] Missing settings.json:
    echo         %SETTINGS_JSON%
    echo.
    echo Aborting uninstall.
    goto :EOF
)

REM Export to environment for PowerShell subprocess
set "SETTINGS_JSON=%SETTINGS_JSON%"

REM ==================================================================
REM SECTION 2 — LOAD REQUIRED VALUES (POWERSHELL -> STREAM)
REM ==================================================================
REM IMPORTANT (v2.4):
REM   - FOR /F command strings MUST be single-line to avoid cmd.exe tokenization
REM     bugs that produce:  "'C:\...\powershell.exe" ... "$p' is not recognized"
REM   - Do NOT quote PowerShell exe path (no spaces). Quoting was getting corrupted.
REM   - Avoid pipelines to keep cmd.exe from interpreting meta characters.
REM ==================================================================

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

set "SERVICE_NAME="
set "LOGS_REL="
set "TASK_FOLDER="
set "TASK_NAME_USER="

for /f "delims=" %%S in ('%PS% -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SETTINGS_JSON; try { $cfg=ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $p); $v=[string]$cfg.services.guard.name; if([string]::IsNullOrWhiteSpace($v)) { '''' } else { $v.Trim() } } catch { '''' }"') do set "SERVICE_NAME=%%S"

for /f "delims=" %%S in ('%PS% -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SETTINGS_JSON; try { $cfg=ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $p); $v=[string]$cfg.paths.logs; if([string]::IsNullOrWhiteSpace($v)) { ''logs'' } else { $v.Trim() } } catch { ''logs'' }"') do set "LOGS_REL=%%S"

for /f "delims=" %%S in ('%PS% -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SETTINGS_JSON; try { $cfg=ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $p); $v=$cfg.tasks.userShutdown.folder; if(-not $v) { $v=$cfg.tasks.tasks.userShutdown.folder }; if([string]::IsNullOrWhiteSpace([string]$v)) { ''\\\\Protepo'' } else { $v.Trim() } } catch { ''\\\\Protepo'' }"') do set "TASK_FOLDER=%%S"

for /f "delims=" %%S in ('%PS% -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:SETTINGS_JSON; try { $cfg=ConvertFrom-Json -InputObject (Get-Content -Raw -LiteralPath $p); $v=$cfg.tasks.userShutdown.name; if(-not $v) { $v=$cfg.tasks.tasks.userShutdown.name }; if([string]::IsNullOrWhiteSpace([string]$v)) { ''VMGuard-Guard-User'' } else { $v.Trim() } } catch { ''VMGuard-Guard-User'' }"') do set "TASK_NAME_USER=%%S"

if not defined SERVICE_NAME (
    echo [FATAL] SERVICE_NAME not resolved from settings.json.
    echo         Expected: services.guard.name
    echo         Settings: %SETTINGS_JSON%
    echo         Aborting uninstall.
    goto :EOF
)

if "%SERVICE_NAME%"=="" (
    echo [FATAL] SERVICE_NAME is empty in settings.json.
    echo         Expected: services.guard.name
    echo         Settings: %SETTINGS_JSON%
    echo         Aborting uninstall.
    goto :EOF
)

if not defined LOGS_REL set "LOGS_REL=logs"
if "%LOGS_REL%"=="" set "LOGS_REL=logs"

if not defined TASK_FOLDER set "TASK_FOLDER=\\Protepo"
if "%TASK_FOLDER%"=="" set "TASK_FOLDER=\\Protepo"
if "%TASK_FOLDER:~-1%"=="\" set "TASK_FOLDER=%TASK_FOLDER:~0,-1%"

if not defined TASK_NAME_USER set "TASK_NAME_USER=VMGuard-Guard-User"
if "%TASK_NAME_USER%"=="" set "TASK_NAME_USER=VMGuard-Guard-User"

REM ==================================================================
REM SECTION 3 — PATHS (ROOT-RELATIVE)
REM ==================================================================

set "EXE_DIR=%VMGUARD_ROOT%\exe"
set "PRUNSRV=%EXE_DIR%\prunsrv.exe"
set "LOG_DIR=%VMGUARD_ROOT%\%LOGS_REL%"
set "TASKS_OUT=%LOG_DIR%\vmguard-schtasks-delete.tmp"

REM Stop timing contract
set "STOP_TIMEOUT_SECONDS=120"
set "POLL_INTERVAL_SECONDS=1"

REM ==================================================================
REM SECTION 4 — VALIDATION
REM ==================================================================

if not exist "%PRUNSRV%" (
    echo [FATAL] prunsrv.exe not found at:
    echo         %PRUNSRV%
    echo.
    echo Aborting uninstall.
    goto :EOF
)

if not exist "%LOG_DIR%" (
    mkdir "%LOG_DIR%" >nul 2>&1
)

echo ===========================================
echo VMGuard Guard Service Uninstall v2.6
echo ===========================================
echo VMGuard root : %VMGUARD_ROOT%
echo Settings     : %SETTINGS_JSON%
echo Service name : %SERVICE_NAME%
echo Procrun      : %PRUNSRV%
echo Logs         : %LOG_DIR%
echo ===========================================
echo.

REM ==================================================================
REM STEP 1 — CHECK IF SERVICE EXISTS
REM ==================================================================

sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [INFO] Service "%SERVICE_NAME%" does not exist.
    echo        Skipping service removal.
    goto :TASK_CLEANUP
)

echo [INFO] Service "%SERVICE_NAME%" detected.

REM ==================================================================
REM STEP 2 — REQUEST SERVICE STOP (BEST EFFORT)
REM ==================================================================

echo [INFO] Requesting service stop...
set "STOP_REQUEST_TIME=%DATE% %TIME%"
sc stop "%SERVICE_NAME%" >nul 2>&1

REM ==================================================================
REM STEP 3 — WAIT FOR STOPPED STATE
REM ==================================================================

echo [INFO] Waiting for service to reach STOPPED state...
set /a ELAPSED=0

:WAIT_LOOP
sc query "%SERVICE_NAME%" | find "STATE" | find "STOPPED" >nul
if not errorlevel 1 (
    echo [INFO] Service is STOPPED.
    goto :SERVICE_STOPPED
)

if %ELAPSED% GEQ %STOP_TIMEOUT_SECONDS% (
    echo.
    echo [ERROR] Timeout waiting for service to stop.
    echo         Current service state:
    sc query "%SERVICE_NAME%"
    echo.
    echo Aborting uninstall to avoid corrupt state.
    goto :EOF
)

timeout /t %POLL_INTERVAL_SECONDS% /nobreak >nul
set /a ELAPSED+=%POLL_INTERVAL_SECONDS%
goto :WAIT_LOOP

:SERVICE_STOPPED

REM Log STOP duration for postmortem diagnostics (avoid redirection tokens inside message)
set "STOP_COMPLETE_TIME=%DATE% %TIME%"
>> "%LOG_DIR%\vmguard-guard-stop-duration.log" 2>nul (
  echo [%STOP_COMPLETE_TIME%] STOP requested at: %STOP_REQUEST_TIME% ^| STOP confirmed at: %STOP_COMPLETE_TIME%
)

REM ==================================================================
REM STEP 4 — DELETE SERVICE VIA PROCRUN
REM ==================================================================

echo [INFO] Removing service via Procrun...
"%PRUNSRV%" //DS//%SERVICE_NAME%

if errorlevel 1 (
    echo.
    echo [ERROR] Procrun failed to delete the service.
    echo         Manual cleanup may be required.
    goto :EOF
)

REM ==================================================================
REM STEP 5 â€” DELETE USER SHUTDOWN TASKS (BEST EFFORT)
REM ==================================================================

:TASK_CLEANUP
set "TASK_USER=%TASK_FOLDER%\%TASK_NAME_USER%"
set "TASK_USER_LEGACY=\Protepo\VMGuard\VMGuard-User-Shutdown-Delegate"
set "TASK_USER_LEGACY_SHORT=VMGuard-User-Shutdown-Delegate"
set "TASK_USER_LEGACY_ALT=\Protepo\VMGuard-User-Shutdown-Delegate"

echo [INFO] Removing scheduled tasks (user shutdown)...
call :DELETE_TASK "%TASK_USER%"
call :DELETE_TASK "%TASK_USER_LEGACY%"
call :DELETE_TASK "%TASK_USER_LEGACY_SHORT%"
call :DELETE_TASK "%TASK_USER_LEGACY_ALT%"

REM ==================================================================
REM FINAL
REM ==================================================================

echo.
echo [SUCCESS] VMGuard Guard Service uninstalled cleanly.
echo.
endlocal
exit /b 0

:DELETE_TASK
set "TN=%~1"
if "%TN%"=="" exit /b 0
echo [INFO] Deleting scheduled task (best effort)...
echo        schtasks /Delete /TN "%TN%" /F
schtasks /Delete /TN "%TN%" /F > "%TASKS_OUT%" 2>&1
if errorlevel 1 (
    call :ECHO_FILE "%TASKS_OUT%"
) else (
    echo [PASS] Task deleted or task did not exist: %TN%
)
if exist "%TASKS_OUT%" del "%TASKS_OUT%" >nul 2>&1
exit /b 0

:ECHO_FILE
set "FILE=%~1"
if exist "%FILE%" (
    for /f "usebackq delims=" %%L in ("%FILE%") do echo        %%L
)
exit /b 0


