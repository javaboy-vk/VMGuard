@echo off
REM ============================================================
REM VMGuard Guard Service - STOP HELPER
REM File: vmguard-guard-stop.cmd
REM Author: javaboy-vk
REM Version: 2.4
REM Date   : 2026-01-13
REM
REM PURPOSE:
REM   Hardened STOP entrypoint for VMGuard Guard under Apache Procrun.
REM
REM RESPONSIBILITIES:
REM   1) Signal Guard kernel STOP event (best-effort)
REM   2) Terminate the *correct* service host PID (no global kills)
REM   3) Use gentle termination first, then escalate (bounded)
REM   4) NEVER block, NEVER fail, ALWAYS return exit code 0
REM
REM WHY THIS EXISTS:
REM   - Procrun exe-mode may not unwind the run loop after STOP helpers.
REM   - SCM waits on the service process (prunsrv.exe) and will hang until
REM     StopTimeout if the host doesn't exit.
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ============================================================
REM CONFIGURATION
REM ============================================================

set SERVICE_NAME=VMGuard-Guard
set BASE_DIR=P:\Scripts\VMGuard
set POWERSHELL=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
set STOP_SIGNAL_PS1=%BASE_DIR%\guard\vmguard-guard-stop-event-signal.ps1

set SOFT_WAIT_SECONDS=3
set HARD_WAIT_SECONDS=2

REM ============================================================
REM STEP 1 — SIGNAL GUARD STOP EVENT (BEST EFFORT)
REM ============================================================

if exist "%STOP_SIGNAL_PS1%" (
    "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%STOP_SIGNAL_PS1%" >nul 2>&1
)

REM ============================================================
REM STEP 2 — DISCOVER THE SERVICE HOST PID (AUTHORITATIVE)
REM ============================================================

set SVC_PID=
for /f "tokens=2 delims=:" %%a in ('sc queryex "%SERVICE_NAME%" ^| findstr /I "PID"') do (
    set SVC_PID=%%a
)

if defined SVC_PID (
    for /f "tokens=* delims= " %%b in ("!SVC_PID!") do set SVC_PID=%%b
)

if not defined SVC_PID goto :DONE
if "!SVC_PID!"=="0" goto :DONE

REM ============================================================
REM STEP 3 — REQUEST GENTLE TERMINATION FIRST
REM ============================================================

taskkill /PID !SVC_PID! /T >nul 2>&1
call :WAIT_PID_GONE !SVC_PID! %SOFT_WAIT_SECONDS%
if errorlevel 0 goto :DONE

REM ============================================================
REM STEP 4 — ESCALATE (BOUNDED) IF STILL ALIVE
REM ============================================================

taskkill /PID !SVC_PID! /T /F >nul 2>&1
call :WAIT_PID_GONE !SVC_PID! %HARD_WAIT_SECONDS%

goto :DONE

REM ============================================================
REM HELPER: WAIT FOR PID TO DISAPPEAR (bounded)
REM ============================================================
:WAIT_PID_GONE
set PID_TO_CHECK=%1
set MAX_SECS=%2

set /a i=0
:LOOP
tasklist /FI "PID eq %PID_TO_CHECK%" 2>nul | findstr /R /C:" %PID_TO_CHECK% " >nul
if errorlevel 1 exit /b 0

set /a i+=1
if %i% GEQ %MAX_SECS% exit /b 1

timeout /t 1 /nobreak >nul
goto :LOOP

:DONE
endlocal
exit /b 0
