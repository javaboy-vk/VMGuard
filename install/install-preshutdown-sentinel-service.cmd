@echo off
REM ============================================================
REM VMGuard – Preshutdown Sentinel Service – INSTALL
REM File   : install-preshutdown-sentinel.cmd
REM Version: 1.1.0
REM Author : javaboy-vk
REM Date   : 2026-01-16
REM
REM PURPOSE:
REM   Installs or updates the VMGuard Preshutdown Sentinel service.
REM   This service exists solely to receive SERVICE_CONTROL_PRESHUTDOWN
REM   and trigger the VMGuard Guard STOP release path early.
REM
REM CHANGES v1.1.0:
REM   - Updated binary contract to use bin\ instead of dist\
REM   - Aligned with unified VMGuard install directory
REM   - Removed invalid dependency on VMGuard-Guard
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ==================================================================
REM CANONICAL VMGUARD DIRECTORY CONTRACT
REM ==================================================================

set BASE_DIR=P:\Scripts\VMGuard
set SENTINEL_DIR=%BASE_DIR%\Preshutdown_Sentinel
set BIN_DIR=%SENTINEL_DIR%\bin
set EXE=%BIN_DIR%\vmguard-preshutdown-sentinel.exe

set SVC=VMGuard-Preshutdown-Sentinel

echo.
echo ===========================================
echo  VMGuard Preshutdown Sentinel INSTALL v1.1.0
echo ===========================================
echo.

REM ==================================================================
REM VALIDATION
REM ==================================================================

if not exist "%EXE%" (
  echo [FATAL] Sentinel executable not found:
  echo         %EXE%
  echo.
  echo Build the sentinel first, then re-run this installer.
  exit /b 1
)

echo [PASS] Sentinel executable found.

REM ==================================================================
REM REMOVE ANY EXISTING SERVICE
REM ==================================================================

sc.exe query "%SVC%" >nul 2>&1
if not errorlevel 1 (
    echo [INFO] Stopping existing service...
    sc.exe stop "%SVC%" >nul 2>&1
    timeout /t 2 /nobreak >nul
    echo [INFO] Deleting existing service...
    sc.exe delete "%SVC%" >nul 2>&1
    timeout /t 1 /nobreak >nul
)

REM ==================================================================
REM INSTALL SERVICE
REM ==================================================================

echo [INFO] Creating service...

sc.exe create "%SVC%" ^
  binPath= "\"%EXE%\"" ^
  start= auto ^
  obj= LocalSystem ^
  DisplayName= "VMGuard Preshutdown Sentinel Service"

if errorlevel 1 (
  echo.
  echo [FATAL] Failed to create service.
  exit /b 1
)

sc.exe description "%SVC%" ^
  "VMGuard preshutdown-tier sentinel that signals Guard STOP event early during host shutdown."

echo [PASS] Service created.

REM ==================================================================
REM CONFIGURE PRESHUTDOWN TIER
REM ==================================================================

echo [INFO] Enabling preshutdown tier...

reg add "HKLM\SYSTEM\CurrentControlSet\Services\%SVC%" ^
 /v PreshutdownTimeout ^
 /t REG_DWORD ^
 /d 60000 ^
 /f >nul

if errorlevel 1 (
  echo.
  echo [FATAL] Failed to configure PreshutdownTimeout.
  exit /b 1
)

echo [PASS] Preshutdown tier configured.

REM ==================================================================
REM START SERVICE
REM ==================================================================

echo [INFO] Starting service...
sc.exe start "%SVC%" >nul 2>&1

sc.exe query "%SVC%" | find /I "RUNNING" >nul 2>&1
if errorlevel 1 (
  echo [WARN] Service did not reach RUNNING state.
) else (
  echo [PASS] Service is RUNNING.
)

echo.
echo [SUCCESS] VMGuard Preshutdown Sentinel installed successfully.
echo.
exit /b 0
