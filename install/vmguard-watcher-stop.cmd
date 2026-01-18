@echo off
setlocal ENABLEEXTENSIONS

REM ============================================================
REM VMGuard Watcher Service - STOP HELPER
REM File: vmguard-watcher-stop.cmd
REM Author: javaboy-vk
REM Version: 1.0
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

REM ------------------------------------------------------------
REM STOP EVENT CONTRACT
REM ------------------------------------------------------------
REM This name MUST EXACTLY MATCH the event name used inside
REM the watcher PowerShell script.
REM ------------------------------------------------------------
set STOP_EVENT=Global\VMGuard_Watcher_Stop

REM ------------------------------------------------------------
REM DIAGNOSTIC LOG (BEST EFFORT)
REM ------------------------------------------------------------
REM This log is optional and non-fatal.
REM It provides forensic proof that the STOP hook executed.
REM ------------------------------------------------------------
set LOG_FILE=P:\Scripts\VMGuard\logs\vmguard-watcher-stop-hook.log

echo %DATE% %TIME% - STOP hook invoked >> "%LOG_FILE%" 2>nul

REM ------------------------------------------------------------
REM SIGNAL STOP EVENT (BEST EFFORT)
REM ------------------------------------------------------------
REM Any failure here is INTENTIONALLY swallowed.
REM The only requirement is that this script exits 0.
REM ------------------------------------------------------------
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "try { $h=[System.Threading.EventWaitHandle]::OpenExisting('%STOP_EVENT%'); [void]$h.Set() } catch { }"

echo %DATE% %TIME% - STOP hook completed >> "%LOG_FILE%" 2>nul

REM ------------------------------------------------------------
REM GUARANTEED SUCCESSFUL EXIT
REM ------------------------------------------------------------
endlocal
exit /b 0
