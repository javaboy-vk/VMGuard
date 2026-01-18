<#
================================================================================
 VMGuard – CMD Execution Driver – v1.0
================================================================================
 Script Name : vmguard-cmd-driver.ps1
 Author      : javaboy-vk
 Date        : 2026-01-17
 Version     : 1.0

 PURPOSE
   Provides a unified PowerShell execution backend for all VMGuard .cmd files.

   This script is invoked by CMD shims and is responsible for:
     - Loading VMGuard bootstrap
     - Dispatching high-level actions
     - Acting as the configuration-driven control plane

 RESPONSIBILITIES
   1) Load vmguard-bootstrap.ps1
   2) Validate VMGuard environment
   3) Dispatch requested CMD action
   4) Provide a single upgrade surface for CMD tooling

 NON-RESPONSIBILITIES
   - Does NOT embed configuration
   - Does NOT define services
   - Does NOT hard-code paths
   - Does NOT replace installers (delegates to them)

 LIFECYCLE CONTEXT
   - Called only by CMD entrypoints
   - Serves as the stable evolution surface for CMD tools
================================================================================
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Action
)

# ============================================================
# 1. Bootstrap Import
# ============================================================

. "$PSScriptRoot\vmguard-bootstrap.ps1"

# ============================================================
# 2. Action Dispatch Table
# ============================================================

switch ($Action.ToLower()) {

    "install-guard" {
        Write-Host "VMGuard CMD Driver: INSTALL GUARD"
        Write-Host "Service: $($VMGServices.guard.name)"
        # TODO: call install-guard.ps1 (future refactor)
        break
    }

    "uninstall-guard" {
        Write-Host "VMGuard CMD Driver: UNINSTALL GUARD"
        break
    }

    "install-sentinel" {
        Write-Host "VMGuard CMD Driver: INSTALL SENTINEL"
        $exe = Resolve-VMGPath $VMGServices.sentinel.exe
        Write-Host "Sentinel EXE resolved to:"
        Write-Host "  $exe"
        break
    }

    "env-dump" {
        Write-Host "==========================================="
        Write-Host " VMGuard Environment Dump"
        Write-Host "==========================================="
        Write-Host "Root: $VMGuardRoot"
        Write-Host "Guard Service: $($VMGServices.guard.name)"
        Write-Host "Sentinel EXE: $(Resolve-VMGPath $VMGServices.sentinel.exe)"
        Write-Host "Guard STOP Event: $($VMGEvents.guardStop)"
        Write-Host "Logs Path: $(Resolve-VMGPath $VMGPaths.logs)"
        break
    }

    default {
        Write-Host "ERROR: Unknown VMGuard CMD action: $Action" -ForegroundColor Red
        exit 2001
    }
}

# ============================================================
# 3. Normal Exit
# ============================================================

exit 0
