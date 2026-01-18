@echo off
REM ============================================================
REM VMGuard – Preshutdown Sentinel Service – BUILD
REM Version: 1.2.0
REM Author : javaboy-vk
REM Date   : 2026-01-16
REM
REM PURPOSE:
REM   Builds and publishes the VMGuard Preshutdown Sentinel service
REM   into its production binary directory under the VMGuard tree.
REM
REM CHANGES v1.2.0:
REM   - Introduced canonical production bin directory
REM   - Removed obsolete dist\ output contract
REM   - Ensures vmguard-preshutdown-sentinel.exe is generated
REM ============================================================

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set ROOT=%~dp0
set SRC=%ROOT%src
set BIN=%ROOT%bin

REM ==================================================================
REM PREPARE OUTPUT DIRECTORY
REM ==================================================================

if exist "%BIN%" rmdir /s /q "%BIN%"
mkdir "%BIN%"

echo ===========================================
echo  Building VMGuard Preshutdown Sentinel v1.2.0
echo ===========================================

REM ==================================================================
REM RESTORE
REM ==================================================================

dotnet restore "%SRC%\vmguard-preshutdown-sentinel.csproj"
if errorlevel 1 exit /b 1

REM ==================================================================
REM PUBLISH (EXE PRODUCER)
REM ==================================================================

dotnet publish "%SRC%\vmguard-preshutdown-sentinel.csproj" ^
  -c Release ^
  -r win-x64 ^
  --self-contained false ^
  -o "%BIN%" ^
  -p:UseAppHost=true


if errorlevel 1 exit /b 1

REM ==================================================================
REM VALIDATE OUTPUT
REM ==================================================================

if not exist "%BIN%\vmguard-preshutdown-sentinel.exe" (
    echo.
    echo [FATAL] Build completed but executable not found:
    echo         %BIN%\vmguard-preshutdown-sentinel.exe
    exit /b 1
)

echo.
echo [PASS] Executable generated:
echo        %BIN%\vmguard-preshutdown-sentinel.exe

echo.
echo [SUCCESS] Build complete.
echo Output folder: %BIN%
exit /b 0
