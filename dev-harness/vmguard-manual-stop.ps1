<#
================================================================================
 VMGuard – Manual Stop Trigger – v1.0
================================================================================
 Script Name : vmguard-manual-stop.ps1
 Author      : javaboy-vk
 Date        : 2026-01-07
 Version     : 1.0

 PURPOSE
   Signal the VMGuard STOP named kernel event manually.

================================================================================
#>

param(
    [string]$StopEventName = "Global\VMGuard_Guard_Stop"
)

Write-Host "==========================================="
Write-Host "VMGuard  Manual Stop Trigger  v1.0"
Write-Host "==========================================="

try {
    $ev = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
    $null = $ev.Set()
    Write-Host "STOP event signaled."
    $ev.Close()
} catch {
    Write-Host "FAILED to signal STOP event: $($_.Exception.Message)"
}
