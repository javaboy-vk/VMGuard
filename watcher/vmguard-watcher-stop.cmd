@echo off
setlocal ENABLEEXTENSIONS

REM ============================================================
REM VMGuard Watcher Service - STOP HELPER
REM File: vmguard-watcher-stop.cmd
REM Author: javaboy-vk
REM Version: 1.3
REM Date   : 2026-01-19
REM
REM ============================================================
REM PURPOSE
REM ============================================================
REM
REM   This script is invoked by Apache Procrun as the StopImage
REM   for the VMGuard Watcher Windows service.
REM
REM   Its sole responsibility is to SIGNAL the named kernel
REM   STOP event that the watcher PowerShell script is waiting on.
REM
REM ============================================================
REM CRITICAL DESIGN RULES (DO NOT VIOLATE)
REM ============================================================
REM
REM   - This script MUST ALWAYS exit with code 0
REM   - This script MUST NEVER block or wait
REM   - This script MUST NEVER throw or propagate errors
REM   - This script MUST NOT depend on watcher state
REM
REM   If this script returns a non-zero exit code, Windows
REM   Service Control Manager (SCM) will log Event 7024 and
REM   Procrun will treat the STOP operation as FAILED.
REM
REM ============================================================
REM WHY THIS SCRIPT EXISTS
REM ============================================================
REM
REM   Procrun does NOT reliably execute complex PowerShell
REM   -Command expressions directly as StopParams.
REM
REM   Wrapping the STOP logic in a dedicated .cmd file:
REM     - Eliminates fragile quoting
REM     - Guarantees deterministic STOP behavior
REM     - Allows safe diagnostics if STOP ever misbehaves
REM
REM ============================================================
REM v1.1 NOTES
REM ============================================================
REM   - Removes hard-coded host paths (portability compliance)
REM   - Anchors VMGuard root from script location:
REM        VMGuard\install\vmguard-watcher-stop.cmd  ->  VMGuard\
REM   - Writes diagnostics to VMGuard\logs\ (best effort)
REM
REM v1.2 NOTES
REM ============================================================
REM   - Eliminates hard-coded STOP event name
REM   - Loads STOP event name from canonical config:
REM        VMGuard\conf\settings.json  (events.watcherStop)
REM   - Still guaranteed to exit 0 even if config/event lookup fails
REM
REM v1.3 NOTES
REM ============================================================
REM   - Refactors the PowerShell -Command payload to be readable
REM   - Preserves all v1.2 behavior and the ALWAYS-EXIT-0 contract
REM ============================================================

REM ------------------------------------------------------------
REM PORTABILITY ANCHOR — RESOLVE VMGUARD ROOT
REM ------------------------------------------------------------
set SCRIPT_DIR=%~dp0
IF "%SCRIPT_DIR:~-1%"=="\" set SCRIPT_DIR=%SCRIPT_DIR:~0,-1%

FOR %%I IN ("%SCRIPT_DIR%\..") DO set BASE_DIR=%%~fI

set LOG_DIR=%BASE_DIR%\logs
set LOG_FILE=%LOG_DIR%\vmguard-watcher-stop-hook.log

REM Canonical settings.json path (bootstrap rule)
set SETTINGS_JSON=%BASE_DIR%\conf\settings.json

REM Best-effort log dir creation (non-fatal)
if not exist "%LOG_DIR%" (
    mkdir "%LOG_DIR%" >nul 2>&1
)

REM ------------------------------------------------------------
REM DIAGNOSTIC LOG (BEST EFFORT)
REM ------------------------------------------------------------
echo %DATE% %TIME% - STOP hook invoked >> "%LOG_FILE%" 2>nul
echo %DATE% %TIME% - BASE_DIR=%BASE_DIR% >> "%LOG_FILE%" 2>nul
echo %DATE% %TIME% - SETTINGS_JSON=%SETTINGS_JSON% >> "%LOG_FILE%" 2>nul

REM ------------------------------------------------------------
REM SIGNAL STOP EVENT (BEST EFFORT, CONFIG-DRIVEN)
REM ------------------------------------------------------------
REM The STOP event name is sourced from:
REM   settings.json -> events.watcherStop
REM
REM Any failure here is INTENTIONALLY swallowed.
REM The only requirement is that this script exits 0.
REM ------------------------------------------------------------

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command ^
"try { ^
    $SettingsPath = '%SETTINGS_JSON%'; ^
    if (-not (Test-Path -LiteralPath $SettingsPath)) { ^
        'NOCONFIG'; ^
        exit 0; ^
    } ^
    $cfg = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json; ^
    $evt = $cfg.events.watcherStop; ^
    if ([string]::IsNullOrWhiteSpace($evt)) { ^
        'NOEVENT'; ^
        exit 0; ^
    } ^
    $h = [System.Threading.EventWaitHandle]::OpenExisting($evt); ^
    [void]$h.Set(); ^
    'SIGNALED:' + $evt; ^
} catch { ^
    'ERROR:' + $_.Exception.Message; ^
}" >> "%LOG_FILE%" 2>nul

echo %DATE% %TIME% - STOP hook completed >> "%LOG_FILE%" 2>nul

REM ------------------------------------------------------------
REM GUARANTEED SUCCESSFUL EXIT
REM ------------------------------------------------------------
endlocal
exit /b 0
