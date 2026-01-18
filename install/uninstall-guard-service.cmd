@echo off
setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ============================================================
REM VMGuard Guard Service - UNINSTALL
REM File: uninstall-guard-service.cmd
REM Author: javaboy-vk
REM Version: 1.0
REM
REM PURPOSE:
REM   Cleanly uninstalls the VMGuard Guard Windows service.
REM
REM   It strictly follows the Windows service lifecycle:
REM
REM     1. Request STOP
REM     2. Wait until STATE = STOPPED
REM     3. Only then delete the service via Procrun
REM
REM   This avoids STOP_PENDING race conditions and
REM   Windows Service Control Manager corruption.
REM
REM WHAT THIS SCRIPT DOES:
REM   1. Verifies the service exists
REM   2. Requests STOP
REM   3. Polls until STOPPED
REM   4. Logs stop duration
REM   5. Deletes the service safely
REM
REM v1.0 NOTES:
REM   - Initial VMGuard Guard service uninstaller
REM   - Follows Watcher uninstall lifecycle discipline
REM ============================================================

REM ==================================================================
REM CONFIGURATION (MUST MATCH INSTALL SCRIPT)
REM ==================================================================

set SERVICE_NAME=VMGuard-Guard

set BASE_DIR=P:\Scripts\VMGuard
set EXE_DIR=%BASE_DIR%\exe
set PRUNSRV=%EXE_DIR%\prunsrv.exe
set LOG_DIR=%BASE_DIR%\logs

REM Stop timing contract
set STOP_TIMEOUT_SECONDS=120
set POLL_INTERVAL_SECONDS=1


REM ==================================================================
REM VALIDATION
REM ==================================================================

if not exist "%PRUNSRV%" (
    echo [FATAL] prunsrv.exe not found at:
    echo         %PRUNSRV%
    echo.
    echo Aborting uninstall.
    goto :EOF
)


REM ==================================================================
REM STEP 1 — CHECK IF SERVICE EXISTS
REM ==================================================================

sc query "%SERVICE_NAME%" >nul 2>&1
if errorlevel 1 (
    echo [INFO] Service "%SERVICE_NAME%" does not exist.
    echo        Nothing to uninstall.
    goto :EOF
)

echo [INFO] Service "%SERVICE_NAME%" detected.


REM ==================================================================
REM STEP 2 — REQUEST SERVICE STOP (BEST EFFORT)
REM ==================================================================

echo [INFO] Requesting service stop...

REM Capture STOP request timestamp for diagnostics
set STOP_REQUEST_TIME=%DATE% %TIME%

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

REM Log STOP duration for postmortem diagnostics
set STOP_COMPLETE_TIME=%DATE% %TIME%
echo [%STOP_COMPLETE_TIME%] STOP duration: %STOP_REQUEST_TIME% -> %STOP_COMPLETE_TIME% >> "%LOG_DIR%\vmguard-guard-stop-duration.log" 2>nul


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
REM FINAL
REM ==================================================================

echo.
echo [SUCCESS] VMGuard Guard Service uninstalled cleanly.
echo.
endlocal
exit /b 0
