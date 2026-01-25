@echo off
REM ============================================================
REM VMGuard Guard Service - STOP HELPER
REM File: vmguard-guard-stop.cmd
REM Author: javaboy-vk
REM Version: 3.9
REM Date   : 2026-01-25
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
REM CONFIG DOCTRINE (v3.9):
REM   - NO hard-coded machine paths
REM   - Resolve VMGuard root relative to this script (portable)
REM   - Service name is fixed to VMGuard-Guard for STOP determinism
REM   - No config file parsing inside STOP helper (avoid cmd parsing pitfalls)
REM   - Optional debug logging to logs\guard-stop.log when VMGUARD_STOP_DEBUG=1
REM   - Imports VMGUARD_STOP_DEBUG from conf\env.properties (best-effort)
REM   - No logs are written outside VMGuard\logs
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ============================================================
REM 0) Root Resolution (portable)
REM ============================================================
set SCRIPT_DIR=%~dp0
REM SCRIPT_DIR ends with \ ; root is one level up from guard\
for %%I in ("%SCRIPT_DIR%..") do set VMGUARD_ROOT=%%~fI

set POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
set STOP_SIGNAL_PS1=%VMGUARD_ROOT%\guard\vmguard-guard-stop-event-signal.ps1

set SOFT_WAIT_SECONDS=3
set HARD_WAIT_SECONDS=2

REM ============================================================
REM 0.5) Best-effort import of VMGUARD_STOP_DEBUG from env.properties
REM ============================================================
set "ENV_PROPS=%VMGUARD_ROOT%\conf\env.properties"
if exist "%ENV_PROPS%" (
  for /f "usebackq tokens=1* delims==" %%K in ("%ENV_PROPS%") do (
    if /I "%%K"=="VMGUARD_STOP_DEBUG" set "VMGUARD_STOP_DEBUG=%%L"
  )
)

set "DEBUG_LOG="
if /I "%VMGUARD_STOP_DEBUG%"=="1" (
  set "DEBUG_LOG=%VMGUARD_ROOT%\logs\guard-stop.log"
  if not exist "%VMGUARD_ROOT%\logs" mkdir "%VMGUARD_ROOT%\logs" >nul 2>&1
  echo [%DATE% %TIME%] STOP helper invoked. Root=%VMGUARD_ROOT% >> "%DEBUG_LOG%" 2>nul
)

REM ============================================================
REM 0.5) Service name (fixed)
REM ============================================================
set SERVICE_NAME=VMGuard-Guard

REM ============================================================
REM STEP 1 ??? SIGNAL GUARD STOP EVENT (BEST EFFORT)
REM ============================================================
if exist "%STOP_SIGNAL_PS1%" (
  "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%STOP_SIGNAL_PS1%" >nul 2>&1
)
if defined DEBUG_LOG echo [%DATE% %TIME%] STOP signaler invoked. >> "%DEBUG_LOG%"

REM ============================================================
REM STEP 2 ??? DISCOVER THE SERVICE HOST PID (AUTHORITATIVE)
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
if defined DEBUG_LOG echo [%DATE% %TIME%] Service PID=%SVC_PID% >> "%DEBUG_LOG%"

REM ============================================================
REM STEP 3 ??? REQUEST GENTLE TERMINATION FIRST
REM ============================================================
taskkill /PID !SVC_PID! /T >nul 2>&1
call :WAIT_PID_GONE !SVC_PID! %SOFT_WAIT_SECONDS%
if errorlevel 0 goto :DONE
if defined DEBUG_LOG echo [%DATE% %TIME%] Soft kill timed out. Escalating. >> "%DEBUG_LOG%"

REM ============================================================
REM STEP 4 ??? ESCALATE (BOUNDED) IF STILL ALIVE
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
if defined DEBUG_LOG echo [%DATE% %TIME%] STOP helper exit. >> "%DEBUG_LOG%"
endlocal
exit /b 0










