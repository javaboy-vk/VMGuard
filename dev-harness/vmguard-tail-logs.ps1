<#
================================================================================
 VMGuard – Log Tailer – v1.3
================================================================================
 Script Name : vmguard-tail-logs.ps1
 Author      : javaboy-vk
 Date        : 2026-01-13
 Version     : 1.3

 PURPOSE
   VMGuard log inspection and tailing utility.

 MODES
   - Preview  (default) : show last N lines and return (HARNESS SAFE)
   - Follow             : follow live until Ctrl-C
   - Observer           : persistent lifecycle observer

 v1.3 CHANGE
   - Default mode changed to PREVIEW (non-blocking).
   - Added -Follow switch for live blocking tail.
   - Added -Observer switch for persistent lifecycle observer.
   - Harness options now return to menu automatically.

 v1.2 CHANGE
   - Harness-safe wait logic.
   - Persistent observer support.
================================================================================
#>

param(
    [ValidateSet("guard","watcher","harness")]
    [string]$Which = "guard",

    [string]$BaseDir = "P:\Scripts\VMGuard",

    [int]$Tail = 60,

    [switch]$Follow,     # live tail until Ctrl-C
    [switch]$Observer,   # infinite lifecycle observer

    [int]$WaitTimeout = 10
)

# ------------------------------------------------------------------------------
# LOG TARGET RESOLUTION
# ------------------------------------------------------------------------------

$log = switch ($Which) {
    "guard"   { Join-Path $BaseDir "logs\vmguard-guard.log" }
    "watcher" { Join-Path $BaseDir "logs\vmguard-watcher.log" }
    "harness" { Join-Path $BaseDir "logs\vmguard-dev-harness.log" }
}

Write-Host ""
Write-Host "==========================================="
Write-Host " VMGuard Log Utility"
Write-Host "==========================================="
Write-Host "Target : $Which"
Write-Host "File   : $log"

if ($Observer) { Write-Host "Mode   : observer" }
elseif ($Follow) { Write-Host "Mode   : follow" }
else { Write-Host "Mode   : preview (harness-safe)" }

Write-Host ""

# ------------------------------------------------------------------------------
# WAIT FOR FILE (HARNESS SAFE)
# ------------------------------------------------------------------------------

$elapsed = 0
while (-not (Test-Path $log)) {

    if ($elapsed -ge $WaitTimeout) {
        Write-Host "Log file not found after $WaitTimeout seconds."
        Write-Host "Nothing to display."
        return
    }

    Write-Host "Waiting for log file... ($elapsed/$WaitTimeout)"
    Start-Sleep -Seconds 1
    $elapsed++
}

# ------------------------------------------------------------------------------
# PREVIEW MODE (DEFAULT)
# ------------------------------------------------------------------------------

if (-not $Follow -and -not $Observer) {

    Write-Host "-------------------------------------------"
    Write-Host " Last $Tail lines"
    Write-Host "-------------------------------------------"

    Get-Content -Path $log -Tail $Tail
    Write-Host "-------------------------------------------"
    Write-Host "End of preview. Returning to harness."
    return
}

# ------------------------------------------------------------------------------
# FOLLOW MODE (BLOCKING)
# ------------------------------------------------------------------------------

if ($Follow) {
    Write-Host "-------------------------------------------"
    Write-Host " Following log (Ctrl-C to exit)"
    Write-Host "-------------------------------------------"

    Get-Content -Path $log -Tail $Tail -Wait
    return
}

# ------------------------------------------------------------------------------
# OBSERVER MODE (PERSISTENT)
# ------------------------------------------------------------------------------

while ($true) {

    if (-not (Test-Path $log)) {
        Write-Host "Waiting for log file to be created..."
        Start-Sleep -Seconds 1
        continue
    }

    Write-Host "Log detected. Attaching..."
    Write-Host "-------------------------------------------"

    try {
        Get-Content -Path $log -Tail $Tail -Wait
    }
    catch {
        Write-Host ""
        Write-Host "Log stream interrupted. Re-acquiring..."
        Start-Sleep -Seconds 1
    }
}
