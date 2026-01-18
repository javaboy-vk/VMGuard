<#
================================================================================
 VMGuard – Interactive Guard Runner – v1.0
================================================================================
 Script Name : vmguard-run-interactive.ps1
 Author      : javaboy-vk
 Date        : 2026-01-07
 Version     : 1.0

 PURPOSE
   Run vmguard-service.ps1 interactively for debugging.

================================================================================
#>

param(
    [string]$GuardScript = "P:\Scripts\VMGuard\guard\vmguard-service.ps1"
)

Write-Host "==========================================="
Write-Host "VMGuard  Interactive Guard Runner  v1.0"
Write-Host "==========================================="

if (-not (Test-Path $GuardScript)) {
    Write-Host "ERROR: Guard script not found: $GuardScript"
    exit 1
}

& $GuardScript -DebugMode
