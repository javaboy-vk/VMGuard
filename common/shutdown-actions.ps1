# ==============================================================================
# 7. Guard shutdown transaction hooks (v1.9)
# ==============================================================================
# v1.9 CHANGE:
# - Portability: dot-sources logging.ps1 relative to this module location.
# - No hard-coded VMGuard root paths.
# ==============================================================================

. (Join-Path $PSScriptRoot "logging.ps1")

function Invoke-OnSystemShutdownDetected {
    Write-Log "GUARD HOOK: System shutdown detected."
}

function Invoke-BeforeVmShutdown {
    Write-Log "GUARD HOOK: Before VM shutdown attempt."
}

function Invoke-AfterVmShutdownAttempt {
    param([bool]$Attempted)
    Write-Log "GUARD HOOK: After VM shutdown attempt. Attempted = $Attempted"
}

function Invoke-OnGuardExit {
    Write-Log "GUARD HOOK: Guard exiting."
}
