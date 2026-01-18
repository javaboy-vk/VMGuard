@echo off
REM ============================================================================
REM VMGuard – Developer Harness Launcher – v1.0
REM File: vmguard-dev-menu.cmd
REM Author: javaboy-vk
REM
REM PURPOSE:
REM   Launch the VMGuard developer harness in a process-scoped PowerShell
REM   session with ExecutionPolicy Bypass, without modifying system policy.
REM
REM RESPONSIBILITIES:
REM   - Start PowerShell with -ExecutionPolicy Bypass
REM   - Invoke vmguard-dev-menu.ps1
REM   - Preserve working directory
REM
REM NON-RESPONSIBILITIES:
REM   - Does not change LocalMachine or CurrentUser execution policy
REM   - Does not elevate privileges
REM ============================================================================

set SCRIPT_DIR=%~dp0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%vmguard-dev-menu.ps1"
