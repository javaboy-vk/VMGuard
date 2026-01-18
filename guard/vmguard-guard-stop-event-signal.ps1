<#
================================================================================
 VMGuard – Guard STOP Event Signaler – v1.9
================================================================================
 Script Name : vmguard-guard-stop-event-signal.ps1
 Author      : javaboy-vk
 Date        : 2026-01-14
 Version     : 1.9

 PURPOSE
   Provides a hardened STOP event signaling mechanism for the VMGuard Guard
   service.

   This script is invoked by Procrun STOP hooks and/or by pre-shutdown host
   interceptors and is responsible solely for signaling a named kernel event
   that releases the Guard service’s main thread.

   This script MUST NEVER fail.
   Service STOP must always be best-effort and must always return exit code 0.

 RESPONSIBILITIES
   - Open the named kernel STOP event used by the Guard service
   - Signal the event to release the Guard blocking wait
   - Attempt all known STOP aliases used by the Guard
   - Log STOP signaling attempts and outcomes
   - Always terminate cleanly with exit code 0

 NON-RESPONSIBILITIES
   - Does NOT control Windows services
   - Does NOT perform shutdown logic
   - Does NOT interact with VMware or VM state
   - Does NOT create or manage flag files
   - Does NOT trigger scheduled tasks

 LIFECYCLE CONTEXT
   - Invoked by vmguard-guard-stop.cmd via Procrun StopParams
   - May also be invoked by pre-shutdown interceptors (event-driven tasks)
   - Runs briefly under LocalSystem during service STOP or host shutdown
   - May execute before Guard startup or after Guard termination
   - Must tolerate missing kernel events without failing
   - Terminates immediately after best-effort signaling

 v1.9:
   - Added multi-alias STOP event support (mirrors Guard alias creation)
   - Added host shutdown context detection
   - Hardened logging for shutdown race diagnostics
   - No contract or responsibility changes

 v1.8:
   - Renamed artifact to vmguard-guard-stop-event-signal.ps1
   - Clarified Guard-only, control-plane-only role
   - No functional changes

 v1.7:
   - Aligned comments with Guard v1.7 shutdown-interceptor model
   - Semantic clarification only

 v1.5:
   - Rewritten to conform to VMGuard Script Header & Documentation Standard v1.0

 v1.4:
   - Best-effort signaling hardened
   - Guaranteed exit code 0
   - Detailed STOP diagnostics added
================================================================================
#>

. "P:\Scripts\VMGuard\common\logging.ps1"

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
# IMPORTANT:
# These event names MUST exactly match those used inside vmguard-service.ps1.
#
# Guard currently creates a primary event and multiple aliases to increase
# resilience across different signalers.
#
$StopEventNames = @(
    "Global\VMGuard_Guard_Stop",
    "Global\VMGuard-STOP",
    "Global\VMGuard_Stop",
    "Global\VMGuardStop"
)


# ==============================================================================
# 2. STARTUP / CONTEXT LOGGING
# ==============================================================================
Write-Log "==========================================="
Write-Log "VMGuard Guard STOP event signaler invoked."
Write-Log "Candidate stop events:"
$StopEventNames | ForEach-Object { Write-Log "  - $_" }

# Attempt to infer shutdown context (best-effort only)
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Log "OS state snapshot: BootTime=$($os.LastBootUpTime), LocalTime=$($os.LocalDateTime)"
}
catch {
    Write-Log "OS state snapshot unavailable (likely late shutdown phase)."
}

Write-Log "Purpose: best-effort release of Guard service STOP wait."
Write-Log "==========================================="


# ==============================================================================
# 3. SIGNAL ATTEMPTS (BEST EFFORT BY DESIGN)
# ==============================================================================
$signaled = $false

foreach ($eventName in $StopEventNames) {

    try {

        # IMPORTANT DESIGN NOTE:
        # ----------------------
        # OpenExisting throws if:
        #   - The Guard service has not yet created the event, OR
        #   - The Guard service has already exited and closed the event
        #
        # Both cases are NORMAL during shutdown races.
        # Therefore, this must be wrapped in try/catch and treated as best-effort.
        #
        $ev = [System.Threading.EventWaitHandle]::OpenExisting($eventName)

        # If we reach this line, the Guard service is still alive and waiting.
        # Signal it to release its blocking WaitOne().
        #
        $null = $ev.Set()
        $signaled = $true

        Write-Log "Guard stop event signaled successfully: $eventName"
    }
    catch {
        Write-Log "STOP signal attempt skipped: $eventName (not present or already released)"
    }
}

if (-not $signaled) {
    Write-Log "No STOP events were signaled. Likely causes:"
    Write-Log "  - Guard service not started yet"
    Write-Log "  - Guard service already terminated"
    Write-Log "  - OS deep in shutdown and kernel objects unavailable"
}


# ==============================================================================
# 4. FINALIZATION / EXIT (GOLDEN RULE)
# ==============================================================================
# Golden rule of service STOP helpers:
# -----------------------------------
# This script MUST ALWAYS return exit code 0.
#
# Any non-zero exit code here can:
#   - Cause SCM 7024 errors
#   - Mark the service stop as failed
#   - Interfere with system shutdown
#
Write-Log "vmguard-guard-stop-event-signal.ps1 exiting with code 0 (required for safe STOP signaling)."
exit 0
