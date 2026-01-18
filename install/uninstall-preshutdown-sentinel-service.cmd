@echo off
REM ============================================================
REM VMGuard – Preshutdown Sentinel Service – UNINSTALL
REM Version: 1.0.0
REM Author : javaboy-vk
REM ============================================================

set SVC=VMGuard-Preshutdown-Sentinel
sc.exe stop "%SVC%"
sc.exe delete "%SVC%"
echo [OK] Uninstall attempted.
exit /b 0
