<#
================================================================================
 VMGuard – State Reset Utility – v1.1
================================================================================
 Script Name : vmguard-reset-state.ps1
 Author      : javaboy-vk
 Date        : 2026-01-09
 Version     : 1.1

 PURPOSE
   Reset VMGuard dev state to a clean baseline.

 RESPONSIBILITIES
   - Remove VM flag files.
   - Ensure required directories exist.

 v1.1 CHANGE
   - Corrected -ResetAllFlags behavior:
       * Enumerates all *_running.flag files.
       * Logs each removal.
       * Explicitly logs when no flags exist.
   - Eliminates misleading "No flag present for -ResetAllFlags" message.
================================================================================
#>

param(
    [string]$VmName  = "AtlasW19",
    [string]$BaseDir = "P:\Scripts\VMGuard",
    [switch]$ResetAllFlags
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
Write-Log "VMGuard  State Reset Utility  v1.1 (START)"
Write-Log "==========================================="

$flagDir = Join-Path $BaseDir "flags"
New-Item -ItemType Directory -Force -Path $flagDir | Out-Null

if ($ResetAllFlags) {

    $flags = Get-ChildItem $flagDir -Filter "*_running.flag" -ErrorAction SilentlyContinue

    if (-not $flags) {
        Write-Log "No VM running flags present. State already clean."
    }
    else {
        foreach ($f in $flags) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Removed flag: $($f.Name)"
        }
        Write-Log ("ResetAllFlags completed. {0} flag(s) removed." -f $flags.Count)
    }

}
else {

    $flag = Join-Path $flagDir ("{0}_running.flag" -f $VmName)

    if (Test-Path $flag) {
        Remove-Item $flag -Force
        Write-Log "Removed flag: $flag"
    } 
    else {
        Write-Log "No flag present for VM '$VmName'"
    }

}

Write-Log "==========================================="
Write-Log "VMGuard  State Reset Utility  v1.1 (STOP)"
Write-Log "==========================================="
