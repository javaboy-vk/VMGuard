
# ==============================================================================
# 7. Guard shutdown transaction hooks (v1.7)
# ==============================================================================
# v1.7 CHANGE:
# The Guard is NOT a VM watcher and must not have "OnVmRunning/OnVmStopped"
# semantics. These hooks exist only around the STOP/shutdown transaction.
#
# Why we isolate shutdown actions:
# - We want a stable reactor core.
# - We want easy auditing of “what happens during system shutdown”.
# - We want bounded, best-effort actions.
#
# Hard rules for hooks:
# - No indefinite waits.
# - No polling loops.
# - No long-running orchestration.
# - Log and move on.
# ==============================================================================

. "P:\Scripts\VMGuard\common\logging.ps1"

function Invoke-OnSystemShutdownDetected {
    # v1.7 NOTE:
    # Fired immediately when the STOP signal is observed (after WaitOne()).
    # Use for lightweight logging/telemetry only.
    Write-Log "GUARD HOOK: System shutdown detected."
}

function Invoke-BeforeVmShutdown {
    # v1.7 NOTE:
    # Fired only when the watcher-generated running flag is present.
    # This is a bounded pre-shutdown extension point.
    Write-Log "GUARD HOOK: Before VM shutdown attempt."
}

function Invoke-AfterVmShutdownAttempt {
    param([bool]$Attempted)

    # v1.7 NOTE:
    # Fired after the STOP decision path completes.
    # Attempted=$true  -> we tried to trigger the user-context shutdown task
    # Attempted=$false -> no action was necessary (flag missing)
    Write-Log "GUARD HOOK: After VM shutdown attempt. Attempted = $Attempted"
}

function Invoke-OnGuardExit {
    # v1.7 NOTE:
    # Fired at the very end of STOP handling, right before exit 0.
    # Nothing after this is guaranteed to run.
    Write-Log "GUARD HOOK: Guard exiting."
}