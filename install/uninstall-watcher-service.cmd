@echo off
setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ==============================================================================
REM  VMGuard – Watcher Service Uninstall Script
REM ==============================================================================
REM
REM  AUTHOR
REM  ------
REM  javaboy-vk
REM  Version: 1.3
REM
REM ==============================================================================
REM  PURPOSE
REM ==============================================================================
REM
REM  This script cleanly UNINSTALLS the VMGuard Watcher Windows Service.
REM
REM  It follows the REQUIRED Windows service lifecycle:
REM
REM    1. Request STOP
REM    2. Wait until STATE = STOPPED
REM    3. Only then delete the service via Procrun
REM
REM  This avoids STOP_PENDING race conditions and Procrun uninstall errors.
REM
REM ==============================================================================
REM  GOLDEN RULES
REM ==============================================================================
REM
REM  - NEVER delete a service while it is STOP_PENDING
REM  - NEVER assume stop is instantaneous
REM  - ALWAYS wait explicitly for STOPPED
REM
REM ==============================================================================
REM
REM  v1.2 NOTES
REM  ---------
REM  - Aligns strictly with install-watcher-service.cmd v1.2
REM  - No behavioral changes to lifecycle semantics
REM  - Improves diagnostics if STOP never completes
REM
REM  v1.3 NOTES
REM  ---------
REM  - Adds STOP duration logging (start → end timestamps)
REM  - Increases STOP timeout to match install v1.3
REM  - Preserves all v1.2 lifecycle guarantees
REM
REM ==============================================================================


REM ==============================================================================
REM CONFIGURATION (MUST MATCH install-watcher-service.cmd)
REM ==============================================================================

set SERVICE_NAME=VMGuard-Watcher

set BASE_DIR=P:\Scripts\VMGuard
set EXE_DIR=%BASE_DIR%\exe
set PRUNSRV=%EXE_DIR%\prunsrv.exe
set LOG_DIR=%BASE_DIR%\logs

REM ----------------------------------------------------------------
REM v1.3 CHANGE:
REM STOP timeout increased to match install-watcher-service.cmd v1.3
REM ----------------------------------------------------------------
set STOP_TIMEOUT_SECONDS=120

set POLL_INTERVAL_SECONDS=1


REM ==============================================================================
REM VALIDATION
REM ==============================================================================

if not exist "%PRUNSRV%" (
    echo [ERROR] prunsrv.exe not found at:
    echo         %PRUNSRV%
    echo.
    echo Aborting uninstall.
    goto :EOF
)


REM ==============================================================================
REM STEP 1 — CHECK IF SERVICE EXISTS
REM ==============================================================================

sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [INFO] Service "%SERVICE_NAME%" does not exist.
    echo        Nothing to uninstall.
    goto :EOF
)

echo [INFO] Service "%SERVICE_NAME%" detected.


REM ==============================================================================
REM STEP 2 — REQUEST SERVICE STOP (BEST EFFORT)
REM ==============================================================================

echo [INFO] Requesting service stop...

REM ----------------------------------------------------------------
REM v1.3 ADDITION:
REM Capture STOP request start timestamp for duration logging
REM ----------------------------------------------------------------
set STOP_REQUEST_TIME=%DATE% %TIME%

sc stop "%SERVICE_NAME%" >nul 2>&1


REM ==============================================================================
REM STEP 3 — WAIT FOR STOPPED STATE
REM ==============================================================================

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

REM ----------------------------------------------------------------
REM v1.3 ADDITION:
REM Capture STOP completion timestamp and log duration
REM ----------------------------------------------------------------
set STOP_COMPLETE_TIME=%DATE% %TIME%

echo [%STOP_COMPLETE_TIME%] STOP duration: %STOP_REQUEST_TIME% -> %STOP_COMPLETE_TIME% >> "%LOG_DIR%\vmguard-stop-duration.log" 2>nul


REM ==============================================================================
REM STEP 4 — DELETE SERVICE VIA PROCRUN
REM ==============================================================================

echo [INFO] Removing service via Procrun...
"%PRUNSRV%" //DS//%SERVICE_NAME%

if errorlevel 1 (
    echo.
    echo [ERROR] Procrun failed to delete the service.
    echo         Manual cleanup may be required.
    goto :EOF
)

echo [INFO] Service "%SERVICE_NAME%" successfully removed.


REM ==============================================================================
REM FINAL
REM ==============================================================================

echo.
echo [SUCCESS] VMGuard Watcher Service uninstalled cleanly.
echo.
endlocal
exit /b 0
