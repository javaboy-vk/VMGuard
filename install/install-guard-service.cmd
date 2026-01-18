@echo off
REM ============================================================
REM VMGuard Guard Service - INSTALL
REM File: install-guard-service.cmd
REM Author: javaboy-vk
REM Version: 1.4
REM Date   : 2026-01-16
REM
REM PURPOSE:
REM   Installs or updates the VMGuard Guard as a Windows service
REM   using Apache Procrun (prunsrv.exe) AND enforces installation
REM   of the required user-context scheduled task used for smooth
REM   VM shutdown delegation.
REM
REM WHY THIS SCRIPT IS A .CMD (IMPORTANT):
REM   - Matches existing VMGuard operational tooling
REM   - Avoids PowerShell execution policy issues
REM   - Easy elevation (Run as Administrator)
REM   - Apache Procrun is designed to be driven from cmd.exe
REM
REM WHAT THIS SCRIPT DOES:
REM   1. Validates required binaries and scripts
REM   2. Enforces Protepo Task Scheduler namespace
REM   3. Installs or repairs VMGuard user shutdown task
REM   4. Hard-validates scheduled task availability
REM   5. Installs or updates the Guard service idempotently
REM   6. Configures a hardened STOP contract via a CMD stop helper
REM   7. Enforces LocalSystem execution
REM   8. Enables PID tracking for forced host termination
REM   9. Starts the service
REM   10. Fails loudly on unsafe configurations
REM
REM v1.0 NOTES:
REM   - Initial VMGuard Guard service installer
REM
REM v1.1 CHANGE:
REM   - Added dedicated runtime directory
REM   - Added --PidFile to Procrun configuration
REM
REM v1.2 CHANGE:
REM   - Enforces installation of VMGuard-Guard-User scheduled task
REM   - Introduces Protepo Task Scheduler namespace
REM   - Aligns STOP contract to vmguard-guard-stop-event-signal.ps1
REM   - Installer now owns Guard + Task lifecycle as one unit
REM
REM v1.3 CHANGE:
REM   - Removes invalid preshutdown registration assumptions
REM   - Confirms Guard service remains STOP-driven only
REM   - Formalizes preshutdown responsibility as external to service
REM     (VMGuard Host Shutdown Interceptor + scheduled task layer)
REM   - Guard service remains a hardened STOP contract endpoint
REM   - Early shutdown interception is no longer attempted via procrun
REM
REM v1.4 CHANGE:
REM   - Wires Guard service dependency on VMGuard-Preshutdown-Sentinel
REM   - Enforces deterministic preshutdown ordering
REM   - Sentinel must start before Guard and stop after Guard
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ==================================================================
REM CONFIGURATION (MUST MATCH SERVICE + STOP HELPER + PS1 CONTRACTS)
REM ==================================================================

SET SERVICE_NAME=VMGuard-Guard
SET DISPLAY_NAME=VMGuard Guard Service

SET SERVICE_DESCRIPTION=On host shutdown/service stop, checks Atlas VM running flag and triggers smooth shutdown via user-context scheduled task.

SET BASE_DIR=P:\Scripts\VMGuard
SET EXE_DIR=%BASE_DIR%\exe
SET INSTALL_DIR=%BASE_DIR%\install
SET RUNTIME_DIR=%BASE_DIR%\run
SET GUARD_PS1=%BASE_DIR%\guard\vmguard-service.ps1
SET USER_SHUTDOWN_PS1=%BASE_DIR%\guard\vm-smooth-shutdown.ps1
SET LOG_DIR=%BASE_DIR%\logs

SET PRUNSRV=%EXE_DIR%\prunsrv.exe
SET POWERSHELL=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

SET PID_FILE=%RUNTIME_DIR%\VMGuard-Guard.pid

REM ------------------------------------------------------------------
REM SCHEDULED TASK CONTRACT
REM ------------------------------------------------------------------

SET TASK_FOLDER=\Protepo
SET TASK_NAME=%TASK_FOLDER%\VMGuard-Guard-User

REM ------------------------------------------------------------------
REM STOP CONTRACT
REM ------------------------------------------------------------------

SET STOP_HELPER=%INSTALL_DIR%\vmguard-guard-stop.cmd


REM ==================================================================
REM VALIDATION — HARD FAILURES ONLY
REM ==================================================================

IF NOT EXIST "%PRUNSRV%" (
    echo [FATAL] prunsrv.exe not found at:
    echo         %PRUNSRV%
    exit /b 1
)

IF NOT EXIST "%GUARD_PS1%" (
    echo [FATAL] vmguard-service.ps1 not found at:
    echo         %GUARD_PS1%
    exit /b 1
)

IF NOT EXIST "%USER_SHUTDOWN_PS1%" (
    echo [FATAL] vm-smooth-shutdown.ps1 not found at:
    echo         %USER_SHUTDOWN_PS1%
    exit /b 1
)

IF NOT EXIST "%STOP_HELPER%" (
    echo [FATAL] Guard STOP helper not found at:
    echo         %STOP_HELPER%
    exit /b 1
)

IF NOT EXIST "%LOG_DIR%" mkdir "%LOG_DIR%"
IF NOT EXIST "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%"


REM ==================================================================
REM ENFORCE VMGUARD USER SHUTDOWN TASK
REM ==================================================================

echo.
echo ===========================================
echo  VMGuard Scheduled Task Enforcement
echo ===========================================

schtasks /query /tn "%TASK_NAME%" >nul 2>&1

IF ERRORLEVEL 1 (
    echo [INFO] Scheduled task not found. Installing...

    schtasks /create ^
     /tn "%TASK_NAME%" ^
     /sc ONCE /st 00:00 /f ^
     /tr "\"%POWERSHELL%\" -NoProfile -ExecutionPolicy Bypass -File \"%USER_SHUTDOWN_PS1%\"" ^
     /rl HIGHEST /it

    IF ERRORLEVEL 1 (
        echo.
        echo [FATAL] Failed to create scheduled task:
        echo         %TASK_NAME%
        exit /b 1
    )
)

schtasks /query /tn "%TASK_NAME%" >nul 2>&1
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Scheduled task validation failed after install attempt.
    echo         VMGuard cannot operate without its delegation layer.
    exit /b 1
)

echo [PASS] Scheduled task installed and validated.


REM ==================================================================
REM VMGUARD PRESHUTDOWN SENTINEL WIRING (ADD - v1.4)
REM ==================================================================

echo.
echo ===========================================
echo  VMGuard Preshutdown Sentinel Wiring
echo ===========================================

SET SENTINEL_SVC=VMGuard-Preshutdown-Sentinel

sc query "%SENTINEL_SVC%" >nul 2>&1
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Required preshutdown service not found:
    echo         %SENTINEL_SVC%
    echo         Install the Sentinel first, then re-run this installer.
    exit /b 1
)

echo [PASS] Sentinel service present.

sc query "%SENTINEL_SVC%" | find /I "RUNNING" >nul 2>&1
IF ERRORLEVEL 1 (
    echo [INFO] Sentinel not running. Attempting to start...
    sc start "%SENTINEL_SVC%" >nul 2>&1
)

sc query "%SENTINEL_SVC%" | find /I "RUNNING" >nul 2>&1
IF ERRORLEVEL 1 (
    echo [WARN] Sentinel did not reach RUNNING state (continuing best-effort).
) ELSE (
    echo [PASS] Sentinel is RUNNING.
)

echo [INFO] Enforcing Guard dependency: %SERVICE_NAME% -> %SENTINEL_SVC%
sc config "%SERVICE_NAME%" depend= "%SENTINEL_SVC%" >nul 2>&1
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Failed to set service dependency.
    exit /b 1
)

sc qc "%SERVICE_NAME%" | find /I "%SENTINEL_SVC%" >nul 2>&1
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Dependency verification failed.
    exit /b 1
)

echo [PASS] Sentinel wiring enforced and verified.


REM ==================================================================
REM INSTALL / UPDATE SERVICE
REM ==================================================================

echo.
echo ===========================================
echo  Installing / Updating %SERVICE_NAME%
echo ===========================================

"%PRUNSRV%" //IS//%SERVICE_NAME% ^
 --DisplayName="%DISPLAY_NAME%" ^
 --Description="%SERVICE_DESCRIPTION%" ^
 --Startup=auto ^
 --StartMode=exe ^
 --StartImage="%POWERSHELL%" ^
 --StartParams="-NoProfile -ExecutionPolicy Bypass -File \"%GUARD_PS1%\"" ^
 --StartPath="%BASE_DIR%" ^
 --StopMode=exe ^
 --StopImage="%ComSpec%" ^
 --StopParams="/c \"%STOP_HELPER%\"" ^
 --StopTimeout=120 ^
 --PidFile="%PID_FILE%" ^
 --ServiceUser=LocalSystem ^
 --LogPath="%LOG_DIR%" ^
 --LogPrefix=VMGuard-Guard-procrun ^
 --LogLevel=Info ^
 --StdOutput="%LOG_DIR%\VMGuard-Guard-stdout.log" ^
 --StdError="%LOG_DIR%\VMGuard-Guard-stderr.log"

IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Service installation failed.
    exit /b 1
)


REM ==================================================================
REM GUARDRAIL — VERIFY SERVICE ACCOUNT
REM ==================================================================

sc qc %SERVICE_NAME% | find "SERVICE_START_NAME" | find "LocalSystem" >nul
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Service account is NOT LocalSystem.
    echo Rolling back installation...
    "%PRUNSRV%" //DS//%SERVICE_NAME% >nul 2>&1
    exit /b 1
)

echo [PASS] Service account validated: LocalSystem


REM ==================================================================
REM START SERVICE
REM ==================================================================

echo.
echo Starting service...
sc start %SERVICE_NAME%

echo.
echo [SUCCESS] VMGuard Guard Service and scheduled task installed successfully.
echo.
endlocal
exit /b 0
