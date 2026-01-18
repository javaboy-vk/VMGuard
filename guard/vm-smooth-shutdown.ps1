<#
================================================================================
 VMGuard – VM Smooth Shutdown – v1.7
================================================================================
 Script Name : vm-smooth-shutdown.ps1
 Former Name : vm-shutdown-helper.ps1
 Author      : javaboy-vk
 Date        : 2026-01-06
 Version     : 1.7

 PURPOSE
   Primary smooth shutdown actor for the VMGuard Guard module.

   This script is responsible ONLY for attempting a graceful ("soft") shutdown
   of the Atlas VM using VMware vmrun. It is executed in a user/interactive
   context (typically via scheduled task or explicit invocation by the Guard).

 RESPONSIBILITIES
   1) Attempt a vmrun soft stop of the target VM.
   2) Log what was attempted and what happened.
   3) Exit quickly and cleanly.

 NON-RESPONSIBILITIES
   - This script does NOT decide whether the VM is running.
   - This script does NOT listen for system shutdown.
   - This script does NOT coordinate STOP sequencing.
   - This script does NOT signal kernel STOP events.
   - This script does NOT manage flag files.

   All policy, gating, and shutdown coordination belongs to vmguard-service.ps1.

 LIFECYCLE CONTEXT
   - Invoked by the VMGuard Guard service during system/service STOP.
   - Runs in a user-capable context where VMware user-space operations are valid.
   - May be invoked during late shutdown when supporting services are degrading.
   - Must therefore be best-effort and bounded.

 VERSION HISTORY

   v1.7:
     - Promoted into Guard module as primary smooth-shutdown actor
     - Renamed to vm-smooth-shutdown.ps1
     - Expanded header to VMGuard documentation standard
     - Clarified lifecycle and non-responsibilities
     - No behavioral change

   v1.3:
     - Initial helper script
     - Issued vmrun soft stop from user session

================================================================================
#>

. "P:\Scripts\VMGuard\common\logging.ps1"

# ==============================================================================
# 1. Configuration
# ==============================================================================
# Why these are explicit:
# - This script may run under different contexts (task, manual, Guard-triggered).
# - Absolute paths avoid ambiguity during shutdown.
# - Failures here are a primary diagnostic signal.
#
$VmRun   = "P:\Apps\VMware\Workstation\vmrun.exe"
$VmxPath = "P:\VMs\AtlasW19\AtlasW19.vmx"

# ==============================================================================
# 2. Startup / Context Logging
# ==============================================================================
# Why we log invocation explicitly:
# - Confirms execution context (user vs system) in postmortems.
# - Provides a definitive marker that Guard attempted smooth shutdown.
#
Write-Log "==========================================="
Write-Log "VMGuard VM smooth shutdown invoked (user context expected)."
Write-Log "vmrun   : $VmRun"
Write-Log "vmx     : $VmxPath"

# ==============================================================================
# 3. Smooth shutdown attempt (best-effort)
# ==============================================================================
# CRITICAL DESIGN NOTE:
# ---------------------
# This script performs exactly ONE action:
#   Attempt a graceful VMware soft stop.
#
# It must NOT:
#   - Loop
#   - Poll
#   - Wait for power-off completion
#   - Orchestrate recovery
#
# The Guard service owns STOP boundedness and final guarantees.
#
try {
    & $VmRun stop $VmxPath soft
    Write-Log "vmrun soft stop issued successfully: $VmxPath"

    # We still exit 0 even if the VM ignores the request.
    # Success here only means the command was issued.
    exit 0
}
catch {
    # Failure here does NOT mean system shutdown should fail.
    # It means smooth shutdown was not possible in this context.
    #
    Write-Log "Failed to issue vmrun soft stop." "Error"
    Write-Log "Details: $($_.Exception.Message)" "Error"

    # Exit code is non-zero to indicate failure to the caller,
    # but the Guard service must treat this as best-effort only.
    exit 1
}

# ==============================================================================
# END OF FILE
# ==============================================================================
