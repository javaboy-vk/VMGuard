@echo off
REM ============================================================
REM VMGuard – Preshutdown Sentinel Service – INSTALL
REM File   : install-preshutdown-sentinel-service.cmd
REM Version: 1.2.0
REM Author : javaboy-vk
REM Date   : 2026-01-23
REM
REM PURPOSE:
REM   Installs or updates the VMGuard Preshutdown Sentinel service.
REM   This service exists solely to receive SERVICE_CONTROL_PRESHUTDOWN
REM   and trigger the VMGuard Guard STOP release path early.
REM
REM CHANGES v1.2.0:
REM   - Portability: removed hard-coded BASE_DIR (derive VMGuard root from script location)
REM   - Config-driven: read service name + display/description from conf\settings.json (best-effort)
REM   - Host inputs: best-effort import of conf\env.properties into process env (no Machine env required)
REM   - Canonical sentinel directory: uses settings.json paths.sentinel when present
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

REM ==================================================================
REM 0) ROOT RESOLUTION (PORTABLE)
REM ==================================================================
set SCRIPT_DIR=%~dp0
for %%I in ("%SCRIPT_DIR%..") do set VMGUARD_ROOT=%%~fI

set SETTINGS_JSON=%VMGUARD_ROOT%\conf\settings.json
set ENV_PROPS=%VMGUARD_ROOT%\conf\env.properties

set POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe

REM ==================================================================
REM 0.5) HOST INPUTS IMPORT (BEST-EFFORT, PROCESS-LOCAL)
REM ==================================================================
REM NOTE: This does NOT require Machine environment variables.
REM It only loads env.properties into this installer process for consistency.
if exist "%ENV_PROPS%" (
  for /f "usebackq delims=" %%L in ("%ENV_PROPS%") do (
    set RAW=%%L
    if not "!RAW!"=="" (
      if /i not "!RAW:~0,1!"=="#" if /i not "!RAW:~0,1!"==";" (
        for /f "tokens=1* delims==" %%K in ("%%L") do (
          if not "%%K"=="" (
            for /f "tokens=* delims= " %%A in ("%%K") do set KEY=%%A
            for /f "tokens=* delims= " %%B in ("%%L") do set LINE=%%B
            for /f "tokens=1* delims==" %%X in ("!LINE!") do (
              set "ENVK=%%X"
              set "ENVV=%%Y"
            )
            if not "!ENVK!"=="" set "!ENVK!=!ENVV!"
          )
        )
      )
    )
  )
)

REM ==================================================================
REM 1) CONFIG RESOLUTION (BEST-EFFORT)
REM ==================================================================
set SVC=VMGuard-Preshutdown-Sentinel
set DISPLAY_NAME=VMGuard Preshutdown Sentinel Service
set DESCRIPTION=VMGuard preshutdown-tier sentinel that signals Guard STOP event early during host shutdown.

set SENTINEL_REL=preshutdown_sentinel
if exist "%SETTINGS_JSON%" if exist "%SCRIPT_DIR%read-sentinel-settings.ps1" if exist "%POWERSHELL%" (
  pushd /d "%SCRIPT_DIR%" >nul 2>&1
  if errorlevel 1 goto :CONFIG_DONE
  set "TMP_SETTINGS=_sentinel-settings.tmp"
  "%POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "read-sentinel-settings.ps1" "%SETTINGS_JSON%" > "%TMP_SETTINGS%" 2>nul
  if exist "%TMP_SETTINGS%" (
    for /f "usebackq delims=" %%A in ("%TMP_SETTINGS%") do (
      for /f "tokens=1* delims==" %%K in ("%%A") do set "%%K=%%L"
    )
  )
  popd >nul 2>&1
)
:CONFIG_DONE

if "%SVC%"=="" set SVC=VMGuard-Preshutdown-Sentinel
if "%DISPLAY_NAME%"=="" set DISPLAY_NAME=VMGuard Preshutdown Sentinel Service
if "%DESCRIPTION%"=="" set DESCRIPTION=VMGuard preshutdown-tier sentinel that signals Guard STOP event early during host shutdown.
if "%SENTINEL_REL%"=="" set SENTINEL_REL=preshutdown_sentinel

REM ==================================================================
REM 2) CANONICAL PATHS
REM ==================================================================
set SENTINEL_DIR=%VMGUARD_ROOT%\%SENTINEL_REL%
set BIN_DIR=%SENTINEL_DIR%\bin
set EXE=%BIN_DIR%\vmguard-preshutdown-sentinel.exe

echo.
echo ===========================================
echo  VMGuard Preshutdown Sentinel INSTALL v1.2.0
echo ===========================================
echo.
echo Root        : %VMGUARD_ROOT%
echo Settings    : %SETTINGS_JSON%
echo EnvProps    : %ENV_PROPS%
echo Service     : %SVC%
echo DisplayName : %DISPLAY_NAME%
echo SentinelDir : %SENTINEL_DIR%
echo Exe         : %EXE%
echo.

REM ==================================================================
REM 3) VALIDATION
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
REM 4) UPDATE OR CREATE SERVICE
REM ==================================================================

set SVC_EXISTS=
sc.exe query "%SVC%" >nul 2>&1
if not errorlevel 1 set SVC_EXISTS=1

REM ==================================================================
REM 5) INSTALL SERVICE
REM ==================================================================

if defined SVC_EXISTS (
  echo [INFO] Updating existing service...
  sc.exe stop "%SVC%" >nul 2>&1
  call :WAIT_SVC_STOPPED "%SVC%" 10
  sc.exe config "%SVC%" ^
    binPath= "\"%EXE%\"" ^
    start= auto ^
    obj= LocalSystem ^
    DisplayName= "%DISPLAY_NAME%"
  if errorlevel 1 (
    echo.
    echo [FATAL] Failed to update service configuration.
    echo         The service may be marked for deletion.
    echo         Close Services.msc or reboot, then re-run this installer.
    exit /b 1
  )
) else (
  echo [INFO] Creating service...
  sc.exe create "%SVC%" ^
    binPath= "\"%EXE%\"" ^
    start= auto ^
    obj= LocalSystem ^
    DisplayName= "%DISPLAY_NAME%"
  if errorlevel 1 (
    echo.
    echo [FATAL] Failed to create service.
    echo         The service may be marked for deletion.
    echo         Close Services.msc or reboot, then re-run this installer.
    exit /b 1
  )
)

sc.exe description "%SVC%" ^
  "%DESCRIPTION%"

echo [PASS] Service created.

REM ==================================================================
REM 6) CONFIGURE PRESHUTDOWN TIER
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
REM 7) START SERVICE
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

REM ==================================================================
REM SUBROUTINE: WAIT FOR SERVICE STOPPED (bounded)
REM ==================================================================
:WAIT_SVC_STOPPED
REM Args: %1=ServiceName %2=MaxRetries
setlocal
set "SVCNAME=%~1"
set "RETRIES=%~2"
if "%RETRIES%"=="" set "RETRIES=10"

for /l %%R in (1,1,%RETRIES%) do (
    sc.exe query "%SVCNAME%" | findstr /I "STOPPED" >nul 2>&1
    if not errorlevel 1 (
        endlocal
        exit /b 0
    )
    timeout /t 2 /nobreak >nul
)

endlocal
exit /b 1
