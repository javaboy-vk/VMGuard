<#
================================================================================
 VMGuard – Guard STOP Event Signaler – v2.0
================================================================================
 Script Name : vmguard-guard-stop-event-signal.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 2.0

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

 v2.0:
   - Portability: removed hard-coded root paths; resolves VMGuard root relative to script
   - Config-driven: prefers conf\settings.json events.guardStop (+systemStop) as primary candidates
   - Host inputs: best-effort import of conf\env.properties into process env
   - Contract preserved: best-effort only; ALWAYS exits 0

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

# ==============================================================================
# 0. Portability Bootstrap (Root + Logging) (v2.0)
# ==============================================================================
# Resolve VMGuard root from this script's location (guard\... -> root).
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VMGuardRoot = Resolve-Path (Join-Path $ScriptDir "..")

$LoggingPs1 = Join-Path $VMGuardRoot "common\logging.ps1"

$script:HasWriteLog = $false
if (Test-Path -LiteralPath $LoggingPs1) {
    try {
        . $LoggingPs1
        $script:HasWriteLog = $true
    } catch {
        $script:HasWriteLog = $false
    }
}

function Write-StopLog {
    param([Parameter(Mandatory=$true)][string]$Message)
    if ($script:HasWriteLog) {
        try { Write-Log $Message } catch { Write-Host $Message }
    } else {
        Write-Host $Message
    }
}

# ==============================================================================
# 1. CONFIGURATION (v2.0: settings.json preferred; legacy aliases retained)
# ==============================================================================
# IMPORTANT:
# This script MUST NEVER fail. All config reads are best-effort.
# If config cannot be read, we fall back to legacy stop event aliases.

function Import-VMGuardEnvProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
        foreach ($raw in $lines) {
            $line = $raw.Trim()
            if (-not $line) { continue }
            if ($line.StartsWith("#") -or $line.StartsWith(";")) { continue }

            $idx = $line.IndexOf("=")
            if ($idx -lt 1) { continue }

            $k = $line.Substring(0, $idx).Trim()
            $v = $line.Substring($idx + 1).Trim()
            if ([string]::IsNullOrWhiteSpace($k)) { continue }

            Set-Item -Path ("Env:{0}" -f $k) -Value $v
        }
    } catch {
        # Best-effort only
        return
    }
}

$EnvPropsPath = Join-Path $VMGuardRoot "conf\env.properties"
Import-VMGuardEnvProperties -Path $EnvPropsPath

$SettingsPath = Join-Path $VMGuardRoot "conf\settings.json"
$cfg = $null
try {
    if (Test-Path -LiteralPath $SettingsPath) {
        $cfg = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
    }
} catch {
    $cfg = $null
}

$primary = @()
try {
    if ($cfg -and $cfg.events -and $cfg.events.guardStop) { $primary += [string]$cfg.events.guardStop }
    if ($cfg -and $cfg.events -and $cfg.events.systemStop) { $primary += [string]$cfg.events.systemStop }
} catch {}

# Legacy aliases retained for resilience across versions/signalers.
$legacy = @(
    "Global\VMGuard_Guard_Stop",
    "Global\VMGuard-STOP",
    "Global\VMGuard_Stop",
    "Global\VMGuardStop"
)

$StopEventNames = @()
foreach ($n in ($primary + $legacy)) {
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $t = $n.Trim()
    if (-not ($StopEventNames -contains $t)) { $StopEventNames += $t }
}

# ==============================================================================
# 2. STARTUP / CONTEXT LOGGING
# ==============================================================================
Write-StopLog "==========================================="
Write-StopLog "VMGuard Guard STOP event signaler invoked."
Write-StopLog "Candidate stop events:"
$StopEventNames | ForEach-Object { Write-StopLog "  - $_" }

# Attempt to infer shutdown context (best-effort only)
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-StopLog "OS state snapshot: BootTime=$($os.LastBootUpTime), LocalTime=$($os.LocalDateTime)"
}
catch {
    Write-StopLog "OS state snapshot unavailable (likely late shutdown phase)."
}

Write-StopLog "Purpose: best-effort release of Guard service STOP wait."
Write-StopLog "==========================================="

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

        Write-StopLog "Guard stop event signaled successfully: $eventName"
    }
    catch {
        Write-StopLog "STOP signal attempt skipped: $eventName (not present or already released)"
    }
}

if (-not $signaled) {
    Write-StopLog "No STOP events were signaled. Likely causes:"
    Write-StopLog "  - Guard service not started yet"
    Write-StopLog "  - Guard service already terminated"
    Write-StopLog "  - OS deep in shutdown and kernel objects unavailable"
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
Write-StopLog "vmguard-guard-stop-event-signal.ps1 exiting with code 0 (required for safe STOP signaling)."
exit 0
