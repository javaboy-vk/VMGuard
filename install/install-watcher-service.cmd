@echo off
REM ============================================================
REM VMGuard Watcher Service - INSTALL
REM File: install-watcher-service.cmd
REM Author: javaboy-vk
REM Version: 1.3
REM
REM PURPOSE:
REM   Installs or updates the VMGuard Watcher as a Windows service
REM   using Apache Procrun (prunsrv.exe).
REM
REM WHY THIS SCRIPT IS A .CMD (IMPORTANT):
REM   - Matches existing VMGuard operational tooling
REM   - Avoids PowerShell execution policy issues
REM   - Easy elevation (Run as Administrator)
REM   - Apache Procrun is designed to be driven from cmd.exe
REM
REM WHAT THIS SCRIPT DOES:
REM   1. Validates required paths (prunsrv.exe, vm-watcher.ps1)
REM   2. Installs or updates the service idempotently
REM   3. Configures a clean STOP contract via a named kernel event
REM   4. Starts the service
REM   5. VALIDATES service account and fails loudly if incorrect
REM
REM v1.2 NOTES:
REM   - Fixes Procrun argument quoting (required for SCM stability)
REM   - Forces LocalSystem explicitly (no defaults)
REM   - Adds post-install validation guardrail
REM
REM v1.3 NOTES:
REM   - Replaces fragile PowerShell StopParams with a STOP HELPER script
REM   - Ensures STOP hook always succeeds (exit code 0)
REM   - Eliminates SCM 7024 errors during service stop
REM ============================================================

SET SERVICE_NAME=VMGuard-Watcher
SET DISPLAY_NAME=VMGuard Watcher Service

REM ----------------------------------------------------------------
REM v1.1+ ADDITION:
REM Service description shown in services.msc
REM ----------------------------------------------------------------
SET SERVICE_DESCRIPTION=Monitors VMware Workstation VM runtime state using filesystem lock directories and maintains VMGuard flag files.

SET BASE_DIR=P:\Scripts\VMGuard
SET EXE_DIR=%BASE_DIR%\exe
SET INSTALL_DIR=%BASE_DIR%\install
SET WATCHER_PS1=%BASE_DIR%\watcher\vm-watcher.ps1
SET LOG_DIR=%BASE_DIR%\logs

SET PRUNSRV=%EXE_DIR%\prunsrv.exe
SET POWERSHELL=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe

REM ============================================================
REM IMPORTANT CONTRACT:
REM   This STOP EVENT NAME MUST EXACTLY MATCH the value
REM   hard-coded inside vm-watcher.ps1.
REM ============================================================
SET STOP_EVENT=Global\VMGuard_Watcher_Stop

REM ----------------------------------------------------------------
REM v1.3 ADDITION:
REM Dedicated STOP helper invoked by Procrun.
REM This script is part of installation tooling and therefore
REM lives under the \install directory (NOT runtime \exe).
REM ----------------------------------------------------------------
SET STOP_HELPER=%INSTALL_DIR%\vmguard-watcher-stop.cmd


IF NOT EXIST "%PRUNSRV%" (
    echo ERROR: prunsrv.exe not found at %PRUNSRV%
    exit /b 1
)

IF NOT EXIST "%WATCHER_PS1%" (
    echo ERROR: vm-watcher.ps1 not found at %WATCHER_PS1%
    exit /b 1
)

REM ----------------------------------------------------------------
REM v1.3 VALIDATION:
REM Ensure STOP helper exists before installing service
REM ----------------------------------------------------------------
IF NOT EXIST "%STOP_HELPER%" (
    echo ERROR: Stop helper not found at %STOP_HELPER%
    echo        Service STOP would be unsafe without it.
    exit /b 1
)

IF NOT EXIST "%LOG_DIR%" (
    mkdir "%LOG_DIR%"
)

echo Installing / Updating %SERVICE_NAME% ...
REM ------------------------------------------------------------
REM v1.3 CHANGE:
REM Use cmd.exe + STOP helper from \install directory.
REM This eliminates fragile PowerShell StopParams parsing
REM and guarantees STOP always returns exit code 0.
REM
REM v1.3 CHANGE:
REM Increase StopTimeout to allow orderly watcher shutdown
REM ------------------------------------------------------------

"%PRUNSRV%" //IS//%SERVICE_NAME% ^
 --DisplayName="%DISPLAY_NAME%" ^
 --Description="%SERVICE_DESCRIPTION%" ^
 --Startup=auto ^
 --StartMode=exe ^
 --StartImage="%POWERSHELL%" ^
 --StartParams="-NoProfile -ExecutionPolicy Bypass -File \"%WATCHER_PS1%\"" ^
 --StartPath="%BASE_DIR%" ^
 --StopMode=exe ^
 --StopImage="%ComSpec%" ^
 --StopParams="/c \"%STOP_HELPER%\"" ^
 --StopTimeout=120 ^
 --ServiceUser=LocalSystem ^
 --LogPath="%LOG_DIR%" ^
 --LogPrefix=VMGuard-Watcher-procrun ^
 --LogLevel=Info ^
 --StdOutput="%LOG_DIR%\VMGuard-Watcher-stdout.log" ^
 --StdError="%LOG_DIR%\VMGuard-Watcher-stderr.log"

IF ERRORLEVEL 1 (
    echo ERROR: Service installation failed.
    exit /b 1
)

REM ============================================================
REM v1.2 GUARDRAIL — VERIFY SERVICE ACCOUNT
REM ============================================================
REM This prevents silent regressions where Procrun defaults
REM to NT AUTHORITY\LocalService.
REM ============================================================

sc qc %SERVICE_NAME% | find "SERVICE_START_NAME" | find "LocalSystem" >nul
IF ERRORLEVEL 1 (
    echo.
    echo [FATAL] Service account is NOT LocalSystem.
    echo         This configuration is unsupported for VMGuard.
    echo.
    echo         Aborting and uninstalling service to prevent damage.
    "%PRUNSRV%" //DS//%SERVICE_NAME% >nul 2>&1
    exit /b 1
)

echo Service account validated: LocalSystem

echo Starting service...
sc start %SERVICE_NAME%

echo.
echo VMGuard Watcher Service installed and started successfully.
pause
