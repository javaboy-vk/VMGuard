<#
    Module: logging.ps1
    Author: javaboy-vk
    Date: 2026-01-19
    Version: 1.4
    Description:
      Unified logging to a single file and Windows Application Event Log.

      PORTABILITY / DOCTRINE NOTES
      - No hard-coded machine paths.
      - Defaults resolve relative to VMGuard root (bootstrap) when available.
      - Globals may be pre-set by bootstrap/installers to control log placement:
          $Global:VMGuardBaseDir
          $Global:VMGuardLogFile
          $Global:VMGuardSource
#>

# ============================================================
# 0. Canonical Root + Defaults (portable)
# ============================================================

# Prefer canonical root discovered by bootstrap. Fall back to common\.. if bootstrap not present.
if ([string]::IsNullOrWhiteSpace($Global:VMGuardBaseDir)) {

    if (-not [string]::IsNullOrWhiteSpace($Global:VMGuardRoot)) {
        $Global:VMGuardBaseDir = $Global:VMGuardRoot.ToString()
    }
    else {
        try {
            $Global:VMGuardBaseDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        }
        catch {
            # Last resort: current location (better than hard-coding a machine path)
            $Global:VMGuardBaseDir = (Get-Location).Path
        }
    }
}

# Default log directory name (do not require config to exist)
$__VMG_DefaultLogDirName = "logs"
$__VMG_LogDir = Join-Path $Global:VMGuardBaseDir $__VMG_DefaultLogDirName

# If bootstrap/config provided paths domain, honor it (optional).
if ($Global:VMGPaths -and -not [string]::IsNullOrWhiteSpace($Global:VMGPaths.logs)) {
    $__VMG_LogDir = Join-Path $Global:VMGuardBaseDir $Global:VMGPaths.logs
}

# Default log file if not already set by installer/bootstrap.
if ([string]::IsNullOrWhiteSpace($Global:VMGuardLogFile)) {
    $Global:VMGuardLogFile = Join-Path $__VMG_LogDir "vmguard.log"
}

# Default event source if not already set.
if ([string]::IsNullOrWhiteSpace($Global:VMGuardSource)) {
    $Global:VMGuardSource = "VMGuard"
}

# Ensure log directory exists (portable).
try {
    New-Item -ItemType Directory -Force -Path $__VMG_LogDir | Out-Null
} catch {}

# Ensure Application EventLog source exists (best-effort; may require admin).
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($Global:VMGuardSource)) {
        New-EventLog -LogName Application -Source $Global:VMGuardSource
    }
} catch {}

# ============================================================
# 1. Canonical Logger
#    - File log shows: INFO/WARN/ERROR (deterministic)
#    - EventLog uses:  Information/Warning/Error (Windows contract)
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        # Accept canonical + short forms. Internally normalize.
        [ValidateSet("INFO","WARN","ERROR","Information","Warning","Error")]
        [string]$Level = "INFO"
    )

    # Normalize to Windows EntryType set for EventLog correctness
    $entryType = switch ($Level) {
        "INFO"        { "Information" }
        "WARN"        { "Warning" }
        "ERROR"       { "Error" }
        "Information" { "Information" }
        "Warning"     { "Warning" }
        "Error"       { "Error" }
        default       { "Information" }
    }

    # Deterministic display label for file output
    $displayLevel = switch ($entryType) {
        "Information" { "INFO" }
        "Warning"     { "WARN" }
        "Error"       { "ERROR" }
        default       { "INFO" }
    }

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$displayLevel] $Message"

    # File write (best-effort)
    try { Add-Content -Path $Global:VMGuardLogFile -Value $line } catch {}

    # EventLog write (best-effort)
    try {
        $eventId = switch ($entryType) {
            "Information" { 1000 }
            "Warning"     { 2000 }
            "Error"       { 3000 }
            default       { 1000 }
        }

        Write-EventLog -LogName Application -Source $Global:VMGuardSource `
            -EntryType $entryType -EventId $eventId -Message $Message
    } catch {}
}
