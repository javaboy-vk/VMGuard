<#
================================================================================
 VMGuard – Health Check – v1.2
================================================================================
 Script Name : vmguard-healthcheck.ps1
 Author      : javaboy-vk
 Date        : 2026-01-09
 Version     : 1.2

 PURPOSE
   Provide fast diagnostics for VMGuard development and testing.

 RESPONSIBILITIES
   - Validate services, scheduled tasks, paths, and STOP event accessibility.

 NON-RESPONSIBILITIES
   - Does not modify system or VM state.

 v1.1 CHANGE
   - Fixed unused $task variable by logging scheduled task presence and state.
   - Ensured health output is control-plane meaningful and analyzer-clean.
================================================================================
#>

param(
    [string]$GuardServiceName = "VMGuard-Guard",
    [string]$UserTaskName     = "VMGuard-Guard-User",
    [string]$StopEventName    = "Global\VMGuard_Guard_Stop",
    [string]$VmName           = "AtlasW19",
    [string]$BaseDir          = "P:\Scripts\VMGuard"
)

$LogFile = Join-Path $BaseDir "logs\vmguard-dev-harness.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - $Message"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
        Add-Content -Path $LogFile -Value $line
    } catch {}
    Write-Host $line
}

Write-Log "==========================================="
Write-Log "VMGuard  Health Check  v1.2 (START)"
Write-Log "==========================================="

# --------------------------------------------------------------------------
# Filesystem layout
# --------------------------------------------------------------------------
$paths = @("guard","flags","logs","dev-harness")
foreach ($p in $paths) {
    $full = Join-Path $BaseDir $p
    if (Test-Path $full) { Write-Log "[PASS] Path exists: $full" }
    else { Write-Log "[WARN] Path missing: $full" }
}

# --------------------------------------------------------------------------
# Guard service
# --------------------------------------------------------------------------
try {
    $svc = Get-Service -Name $GuardServiceName -ErrorAction Stop
    Write-Log "[PASS] Guard service found: $($svc.Status)"
} catch {
    Write-Log "[FAIL] Guard service missing: $($_.Exception.Message)"
}

# --------------------------------------------------------------------------
# Scheduled task
# --------------------------------------------------------------------------
try {
    $task = Get-ScheduledTask -TaskName $UserTaskName -ErrorAction Stop

    if ($null -ne $task) {
        Write-Log "[PASS] Scheduled task found: $UserTaskName (State=$($task.State))"
    }
}
catch {
    Write-Log "[WARN] User shutdown task $UserTaskName is not installed." 
    Write-Log "[WARN] Smooth VM shutdown cannot be triggered from Guard."
}

# --------------------------------------------------------------------------
# STOP event accessibility
# --------------------------------------------------------------------------
try {
    $ev = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
    Write-Log "[PASS] STOP event openable."
    $ev.Close()
} catch {
    Write-Log "[WARN] STOP event not openable."
}

# --------------------------------------------------------------------------
# VM running flag
# --------------------------------------------------------------------------
$flag = Join-Path $BaseDir ("flags\{0}_running.flag" -f $VmName)
if (Test-Path $flag) { Write-Log "[INFO] VM running flag present." }
else { Write-Log "[INFO] VM running flag not present." }

Write-Log "==========================================="
Write-Log "VMGuard  Health Check  v1.2 (STOP)"
Write-Log "==========================================="
