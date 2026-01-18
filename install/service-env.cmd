@echo off
set SERVICE_NAME=VMGuard
set SERVICE_DISPLAY_NAME=VM Guard Service
set SERVICE_DESCRIPTION=Gracefully shuts down Atlas VM during system shutdown

set BASE_DIR=P:\Scripts\VMGuard
set EXE_DIR=%BASE_DIR%\exe

set PRUNSRV=%EXE_DIR%\prunsrv.exe
set PRUNMGR=%EXE_DIR%\prunmgr.exe
set COMMONS_DAEMON_JAR=%EXE_DIR%\commons-daemon-1.5.1.jar

set POWERSHELL=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
set SERVICE_SCRIPT=%BASE_DIR%\services\vmguard-service.ps1
set STOP_SCRIPT=%BASE_DIR%\services\stop-signal.ps1

set LOG_DIR=%BASE_DIR%\logs
