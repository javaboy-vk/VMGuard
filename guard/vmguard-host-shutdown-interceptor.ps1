<#
================================================================================
 VMGuard – Host Shutdown Interceptor – v1.0.1
================================================================================
 Script Name : vmguard-host-shutdown-interceptor.ps1
 Author      : javaboy-vk
 Date        : 2026-01-14
 Version     : 1.0.1

 PURPOSE
   Trigger VMGuard’s STOP release path early during host shutdown by invoking
   the Guard STOP event signaler before Windows enters deep service teardown.

   This reduces the chance that VMware Workstation suspends the Atlas VM due to
   shutdown race conditions.

 RESPONSIBILITIES
   1) Detect that the script is running in the intended context (best effort).
   2) Log a clear, forensic startup marker indicating host shutdown interception.
   3) Invoke the VMGuard Guard STOP event signaler (best effort).
   4) NEVER fail; always exit code 0.

 NON-RESPONSIBILITIES
   - Does NOT shut down VMware directly.
   - Does NOT call vmrun or interact with VM state.
   - Does NOT manage flag files.
   - Does NOT start/stop VMGuard services.
   - Does NOT schedule tasks (installation does that).

 LIFECYCLE CONTEXT
   - Designed to run under LocalSystem from an Event-Triggered Scheduled Task.
   - Triggered by System log shutdown-related events (e.g., USER32/1074).
   - May run more than once per shutdown sequence depending on OS behavior.
   - Must be safe, fast, idempotent, and best-effort.

 VERSIONING RULES
   - Bump MINOR version if triggers, shutdown semantics, or contract behavior
     change (e.g., new events, timing, STOP signaling sequence).
   - Bump PATCH version for logging-only or non-functional hardening.

================================================================================
#>

# ==============================================================================
# 0. HARD LOGGING BOOTSTRAP (MUST NEVER FAIL)
# ==============================================================================
# This guarantees forensic visibility even if common logging fails or cannot load.

$VMGuardLogRoot = "P:\Scripts\VMGuard\logs"
$BootstrapLog   = Join-Path $VMGuardLogRoot "vmguard-host-shutdown-interceptor.log"

try {
    if (-not (Test-Path $VMGuardLogRoot)) {
        New-Item -ItemType Directory -Path $VMGuardLogRoot -Force | Out-Null
    }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Add-Content -Path $BootstrapLog -Value ""
    Add-Content -Path $BootstrapLog -Value "==========================================="
    Add-Content -Path $BootstrapLog -Value " VMGuard Host Shutdown Interceptor v1.0.1"
    Add-Content -Path $BootstrapLog -Value " BOOTSTRAP FIRE CONFIRMED"
    Add-Content -Path $BootstrapLog -Value " Time : $ts"
    Add-Content -Path $BootstrapLog -Value " User : $env:USERNAME"
    Add-Content -Path $BootstrapLog -Value " PID  : $PID"
    Add-Content -Path $BootstrapLog -Value "==========================================="
}
catch {
    # Golden rule: NEVER interfere with shutdown.
}

# ==============================================================================
# 0b. COMMON LOGGING LOAD (BEST EFFORT)
# ==============================================================================
try {
    . "P:\Scripts\VMGuard\common\logging.ps1"
}
catch {
    try {
        Add-Content -Path $BootstrapLog -Value "[WARN] VMGuard common logging failed to load. Continuing with bootstrap log only."
    } catch {}
}

# Local safety logger that always falls back to bootstrap file
function Write-InterceptorLog {
    param([string]$Message)

    try {
        if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
            Write-Log $Message
        }
        else {
            Add-Content -Path $BootstrapLog -Value "[BOOT] $Message"
        }
    }
    catch {
        try { Add-Content -Path $BootstrapLog -Value "[BOOT] $Message" } catch {}
    }
}

# ==============================================================================
# 1. CONFIGURATION
# ==============================================================================
$StopSignalerScript = "P:\Scripts\VMGuard\guard\vmguard-guard-stop-event-signal.ps1"
$DebounceMs        = 1500
$DebounceMarker   = "P:\Scripts\VMGuard\flags\host_shutdown_interceptor.debounce"

# ==============================================================================
# 2. STARTUP / CONTEXT LOGGING
# ==============================================================================
Write-InterceptorLog "==========================================="
Write-InterceptorLog "VMGuard Host Shutdown Interceptor v1.0.1 (START)"
Write-InterceptorLog "==========================================="
Write-InterceptorLog "Context: pre-teardown STOP signaling attempt."
Write-InterceptorLog "Stop signaler: $StopSignalerScript"
Write-InterceptorLog "Process: PID=$PID User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-InterceptorLog "OS snapshot: BootTime=$($os.LastBootUpTime), LocalTime=$($os.LocalDateTime)"
}
catch {
    Write-InterceptorLog "OS snapshot unavailable (late shutdown or restricted context)."
}

# ==============================================================================
# 3. MAIN ACTION (BEST EFFORT)
# ==============================================================================
try {
    $now = Get-Date
    if (Test-Path $DebounceMarker) {
        $last = Get-Item $DebounceMarker -ErrorAction Stop
        $delta = $now - $last.LastWriteTime
        if ($delta.TotalMilliseconds -lt $DebounceMs) {
            Write-InterceptorLog "Debounce: duplicate invocation within ${DebounceMs}ms window. Exiting."
            exit 0
        }
    }
    New-Item -ItemType File -Path $DebounceMarker -Force | Out-Null
}
catch {
    Write-InterceptorLog "Debounce unavailable (best-effort). Continuing."
}

try {
    if (Test-Path $StopSignalerScript) {
        Write-InterceptorLog "Invoking Guard STOP event signaler (best-effort)..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopSignalerScript | Out-Null
        Write-InterceptorLog "Guard STOP event signaler invocation completed."
    }
    else {
        Write-InterceptorLog "Stop signaler not found: $StopSignalerScript"
    }
}
catch {
    Write-InterceptorLog "Stop signaler invocation failed (best-effort)."
    Write-InterceptorLog "Details: $($_.Exception.Message)"
}

# ==============================================================================
# 4. FINALIZATION / EXIT (GOLDEN RULE)
# ==============================================================================
Write-InterceptorLog "VMGuard Host Shutdown Interceptor v1.0.1 (STOP)"
Write-InterceptorLog "==========================================="

try {
    Add-Content -Path $BootstrapLog -Value "[END] $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") Interceptor exiting."
}
catch {}

exit 0
