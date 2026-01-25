<#
================================================================================
 VMGuard – VM Watcher Service
================================================================================

 Author: javaboy-vk
 Version: 1.2.6
 Date   : 2026-01-25

================================================================================
 THIS FILE IS BOTH CODE *AND* DOCUMENTATION
================================================================================

 This script is intentionally verbose.

 The comments are not noise.
 The comments are not optional.
 The comments explain *why* things are done in a specific way.

 Assume that:
   - The next person maintaining this script is junior
   - They may not understand PowerShell threading
   - They may not understand FileSystemWatcher behavior
   - They may not understand debouncing
   - They may accidentally "simplify" the code and break it

 If you remove comments, you are increasing operational risk.

================================================================================
 HIGH-LEVEL PURPOSE (WHAT PROBLEM THIS SOLVES)
================================================================================

 This script determines whether a VMware Workstation virtual machine (VM)
 is RUNNING or STOPPED.

 It does NOT:
   - call vmrun.exe
   - talk to VMware APIs
   - rely on a logged-in user
   - poll in a loop
   - use sleep

 Instead, it relies on a **filesystem invariant**:

   When a VMware VM is running, VMware creates a DIRECTORY:
       <VM_NAME>.vmdk.lck

   When the VM stops, that directory disappears.

 This is:
   ✔ reliable
   ✔ user-independent
   ✔ SYSTEM-context safe
   ✔ version-agnostic

================================================================================
 CRITICAL POWERSHELL ENGINE RULE (DO NOT IGNORE)
================================================================================

 ❌ PowerShell code MUST NOT execute on background threads.

 Background threads include:
   - System.Threading.Timer callbacks
   - FileSystemWatcher callbacks
   - Any .NET event handler

 If PowerShell code runs there, the process will CRASH with errors like:
   - Management.Automation.PSInvalidOperation
   - ScriptBlock.GetContextFromTLS
   - VS Code terminal exit code 2

 THEREFORE:
   - Background threads run **C# ONLY**
   - C# code only signals kernel objects
   - ALL PowerShell logic runs in ONE place:
       the main event loop

================================================================================
 WHY FILESYSTEM EVENTS ARE NOT "STATE"
================================================================================

 FileSystemWatcher events are extremely noisy.

 VMware may generate:
   - dozens of Created events
   - dozens of Deleted events
   - Renamed events
   - Changed events

 All for a single VM start or stop.

 Therefore:
   - Filesystem events are treated ONLY as wake-up signals
   - They do NOT directly mean "VM started" or "VM stopped"

================================================================================
 WHY DEBOUNCING EXISTS (THIS IS NOT OPTIONAL)
================================================================================

 Without debouncing, logs would look like this:

   VM STOPPED
   VM RUNNING
   VM STOPPED
   VM RUNNING

 This happens because VMware rapidly creates and deletes files during shutdown.

 Debouncing:
   - waits briefly for filesystem noise to stop
   - evaluates the VM state ONCE
   - logs ONE clean transition

================================================================================
 MAINTAINER GOLDEN RULES (DO NOT VIOLATE)
================================================================================

 1. DO NOT add polling loops
 2. DO NOT add Start-Sleep calls
 3. DO NOT run PowerShell in timers or callbacks
 4. DO NOT compute VM state outside the main loop
 5. DO NOT remove debounce logic
 6. DO NOT log per filesystem event in production

================================================================================
 v1.2 CHANGE SUMMARY
================================================================================
 - Removes all hard-coded paths (portability compliance).
 - Loads VMGuard root + central configuration via vmguard-bootstrap.ps1.
 - Aligns logging bootstrap and startup banners with Guard portability model.

 v1.2.1 CHANGE SUMMARY
 - Clears stale Watcher stop event at startup to prevent immediate self-termination.

 v1.2.2 CHANGE SUMMARY
 - Updates documentation to match canonical config location:
       VMGuard\conf\settings.json

 v1.2.3 CHANGE SUMMARY
 - Fixes invalid dynamic env var reference ($env:$VarName) by using
   [Environment]::GetEnvironmentVariable(...) only.

 v1.2.4 CHANGE SUMMARY
 - Eliminates PSScriptAnalyzer "assigned but never used" warnings by:
     - explicitly creating $LogsDir / $FlagsDir directories
     - logging $LogsDir / $FlagsDir
     - logging a lock-directory probe using $LockDirPath

 v1.2.6 CHANGE SUMMARY
 - VM identity resolved exclusively from env.properties (no runtime in settings.json)
 - VM name derived from VMX path or VM directory when explicit name is absent

 v1.2.5 CHANGE SUMMARY
 - Eliminates "service starts then dies" when VM directory is missing/inaccessible
   at startup by entering a STOP-responsive HOLD state:
     - No polling loops
     - No Start-Sleep calls
     - No PowerShell execution on background threads
   A C# Timer signals an AutoResetEvent that wakes the main loop to retry.
================================================================================
#>

param(
    # DebugMode:
    # When enabled, the script pauses at startup so VS Code can attach.
    # NEVER enable this in a production service.
    [switch]$DebugMode,

    # VerboseFSW:
    # When enabled, raw filesystem events are logged.
    # This is extremely noisy and intended ONLY for debugging.
    [switch]$VerboseFSW
)

# ==============================================================================
# SECTION 0 — BOOTSTRAP (PORTABILITY ANCHOR + CONFIG LOADER)
# ==============================================================================
# VMGuard is directory-portable.
# This script MUST NOT contain drive letters or fixed host paths.
#
# The VMGuard root is discovered from script self-location:
#   watcher\vm-watcher.ps1  ->  VMGuard\
#
# Central configuration is loaded by vmguard-bootstrap.ps1 from the canonical
# location:
#   VMGuard\conf\settings.json
#
# IMPORTANT:
#   The bootstrap loader is intentionally minimal.
#   It owns only:
#     - root resolution
#     - config loading
#     - exposure of $VMG / $VMGPaths / $VMGEvents / $VMGServices / $VMGRuntime
#     - path helpers (Resolve-VMGPath)
#
# If bootstrap fails, the environment is invalid and Watcher MUST NOT proceed.

$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$VMGuardRoot = $null

try {
    $VMGuardRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
} catch {
    # Bootstrap failure means we cannot trust *anything* about the environment.
    # Best-effort: write a single raw line to a default relative log location.
    try {
        $FallbackLog = Join-Path (Join-Path $ScriptRoot "..\logs") "vmguard.log"
        New-Item -ItemType Directory -Force -Path (Split-Path $FallbackLog) | Out-Null
        Add-Content -Path $FallbackLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [FATAL] Watcher unable to resolve VMGuard root: $_"
    } catch {}
    exit 1001
}

# ------------------------------------------------------------------------------
# BOOTSTRAP PROOF-OF-LIFE
# This MUST run before logging.ps1 is loaded.
# If this does not appear in the log file, PowerShell never executed.
#
# NOTE:
#   We intentionally write to VMGuardRoot\logs\vmguard.log here, even before
#   vmguard-bootstrap.ps1 validates config. This is a forensic "did we run?"
#   marker, not authoritative config-driven logging.
# ------------------------------------------------------------------------------
$BootstrapLogFile = Join-Path (Join-Path $VMGuardRoot "logs") "vmguard.log"
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $BootstrapLogFile) | Out-Null
    Add-Content -Path $BootstrapLogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - BOOTSTRAP: VMGuard Watcher entered PowerShell."
} catch {}

# Load canonical VMGuard bootstrap (root + config + path helpers)
. (Join-Path $VMGuardRoot "common\vmguard-bootstrap.ps1")

# ==============================================================================
# SECTION 1 — CONFIGURATION (CANONICAL SETTINGS.JSON, NO HARDCODED PATHS)
# ==============================================================================
# This section contains ALL tunable values.
# A junior developer should ONLY modify this section when adapting the script.
#
# IMPORTANT:
#   VMGuard internal paths are ALWAYS relative to VMGuard root.
#   Host-specific VM storage paths MUST NOT be embedded in settings.json.
#
# Canonical config keys (per settings.json):
#   paths.logs
#   paths.flags
#   events.watcherStop
#   services.watcher.eventSource
#
# Canonical host inputs (per conf\env.properties -> process env):
#   VMGUARD_ATLAS_VM_DIR
#   VMGUARD_ATLAS_VMX_PATH
#   VMGUARD_ATLAS_VM_NAME (optional)

# --------------------------------------------------------------------------
# 1.1 Logging formatting policy (config-driven)
# --------------------------------------------------------------------------
$TimestampFormat = $VMG.logging.timestampFormat
if (-not $TimestampFormat) { $TimestampFormat = "yyyy-MM-dd HH:mm:ss" }

$Separator = $VMG.logging.separator
if (-not $Separator) { $Separator = "===========================================" }

# --------------------------------------------------------------------------
# 1.2 VM target identity (REQUIRED)
# --------------------------------------------------------------------------
# Watcher must know:
#   - VM name (for flag naming + lock directory name)
#   - VM directory (host path where VM files reside)
#
# IMPORTANT:
#   Host-specific paths live ONLY in conf\env.properties.
#   settings.json must not carry absolute paths or runtime identity.

function Get-VMGEnvValue {
    param([Parameter(Mandatory)][string]$Name)

    $v = [Environment]::GetEnvironmentVariable($Name, "Process")
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, "Machine") }
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v.Trim()
}

$VmDirEnvName = "VMGUARD_ATLAS_VM_DIR"
$VmDir = Get-VMGEnvValue $VmDirEnvName

$VmVmxEnvName = "VMGUARD_ATLAS_VMX_PATH"
$VmVmx = Get-VMGEnvValue $VmVmxEnvName

$VmNameEnvName = "VMGUARD_ATLAS_VM_NAME"
$VmName = Get-VMGEnvValue $VmNameEnvName

if (-not $VmName) {
    if ($VmVmx) { $VmName = [System.IO.Path]::GetFileNameWithoutExtension($VmVmx) }
    elseif ($VmDir) { $VmName = Split-Path -Leaf $VmDir }
}

if (-not $VmName) {
    try {
        Add-Content -Path $BootstrapLogFile -Value "$(Get-Date -Format $TimestampFormat) [FATAL] VM name not resolved. Set env var '$VmNameEnvName' or provide '$VmVmxEnvName'."
    } catch {}
    exit 1010
}

if (-not $VmDir) {
    try {
        Add-Content -Path $BootstrapLogFile -Value "$(Get-Date -Format $TimestampFormat) [FATAL] VM directory not resolved. Set env var '$VmDirEnvName' in conf\\env.properties."
    } catch {}
    exit 1012
}

# VMware runtime indicator:
# IMPORTANT: This is a DIRECTORY, not a file.
$LockDirPath = Join-Path $VmDir "$VmName.vmdk.lck"

# --------------------------------------------------------------------------
# 1.3 VMGuard internal runtime paths (CONFIG-DRIVEN, ROOT-RELATIVE)
# --------------------------------------------------------------------------
# Logging and flags MUST live under VMGuard root (portable).

$LogsDir  = $null
$FlagsDir = $null

# Resolve-VMGPath is a bootstrap helper that returns an absolute path anchored
# to the VMGuard root, based on config-relative paths.
if ($VMGPaths -and $VMGPaths.logs)  { $LogsDir  = Resolve-VMGPath $VMGPaths.logs }
if ($VMGPaths -and $VMGPaths.flags) { $FlagsDir = Resolve-VMGPath $VMGPaths.flags }

# If the config omits these keys, we fail closed rather than quietly diverge.
# Watcher must match Guard-level determinism and directory doctrine.
if (-not $LogsDir) {
    try { Add-Content -Path $BootstrapLogFile -Value "$(Get-Date -Format $TimestampFormat) [FATAL] Missing config: paths.logs" } catch {}
    exit 1013
}
if (-not $FlagsDir) {
    try { Add-Content -Path $BootstrapLogFile -Value "$(Get-Date -Format $TimestampFormat) [FATAL] Missing config: paths.flags" } catch {}
    exit 1013
}

# Single shared log file used by all VMGuard components
$LogFile  = Join-Path $LogsDir "vmguard.log"

# Flag file created when VM is running
$FlagFile = Join-Path $FlagsDir "${VmName}_running.flag"

# --------------------------------------------------------------------------
# 1.4 STOP event (CANONICAL KEY)
# --------------------------------------------------------------------------
# Named Windows kernel event used by the service wrapper to stop this script.
$ServiceStopEventName = $VMG.events.watcherStop
if (-not $ServiceStopEventName) {
    # Portable fallback (non-path) if config key is absent.
    $ServiceStopEventName = "Global\VMGuard_Watcher_Stop"
}

# --------------------------------------------------------------------------
# 1.5 Event Log Source (CANONICAL KEY)
# --------------------------------------------------------------------------
# Windows Application Event Log source name
$EventSource = $VMG.services.watcher.eventSource
if (-not $EventSource) {
    $EventSource = "VMGuard-Watcher"
}

# --------------------------------------------------------------------------
# 1.6 Heartbeat + debounce
# --------------------------------------------------------------------------
$HeartbeatMinutes    = 5
$HeartbeatIntervalMs = $HeartbeatMinutes * 60 * 1000

# Debounce window:
# Time to wait after filesystem activity before evaluating VM state
$StateStabilizationMs = 1500

# ==============================================================================
# SECTION 2 — WINDOWS EVENT LOG INITIALIZATION
# ==============================================================================
# Windows requires event sources to exist before logging.
# This is a one-time system operation.

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        New-EventLog -LogName Application -Source $EventSource
    }
} catch {
    # Failure here is NOT fatal.
    # File logging will still work.
}

# ==============================================================================
# SECTION 3 — LOGGING INITIALIZATION
# ==============================================================================
# logging.ps1 defines Write-Log, which:
#   - writes to the shared log file
#   - writes to the Windows Application Event Log
#
# IMPORTANT:
#   Portable logging requires that logging.ps1 bind to the VMGuard root at runtime.
#   The Guard portability model uses global variables as the handoff contract.

$Global:VMGuardBaseDir = $VMGuardRoot
$Global:VMGuardLogFile = $LogFile
$Global:VMGuardSource  = $EventSource

. (Join-Path $VMGuardRoot "common\logging.ps1")

# Ensure required directories exist (explicitly use config-materialized dirs)
New-Item -ItemType Directory -Force -Path $LogsDir  | Out-Null
New-Item -ItemType Directory -Force -Path $FlagsDir | Out-Null

# Preserve legacy Split-Path directory assertions (harmless redundancy)
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile)  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $FlagFile) | Out-Null

# ==============================================================================
# SECTION 4 — STARTUP LOGGING
# ==============================================================================
# A visible separator helps operators visually identify restarts.

Write-Log $Separator
Write-Log "VMGuard Watcher starting (SYSTEM context)."
Write-Log "Version                : 1.2.6"
Write-Log "VMGuard root           : $VMGuardRoot"
Write-Log "Config path            : $VMGuardConfigPath"
Write-Log "VM name                : $VmName"
Write-Log "VM directory           : $VmDir"
Write-Log "VM dir env var         : $VmDirEnvName"
Write-Log "Logs directory         : $LogsDir"
Write-Log "Flags directory        : $FlagsDir"
Write-Log "Runtime lock directory : $LockDirPath"
Write-Log "Lock dir probe (exists): $(Test-Path -LiteralPath $LockDirPath)"
Write-Log "Log file               : $LogFile"
Write-Log "Flag file              : $FlagFile"
Write-Log "STOP event             : $ServiceStopEventName"
Write-Log "Heartbeat interval     : $HeartbeatMinutes minute(s)"
Write-Log "Debounce window        : ${StateStabilizationMs}ms"
Write-Log "VerboseFSW             : $VerboseFSW"

# ==============================================================================
# SECTION 5 — DEBUG GATE (VS CODE ONLY)
# ==============================================================================
# When debugging, we intentionally pause execution.
# This allows VS Code to attach BEFORE background activity begins.

if ($DebugMode) {
    Write-Log "DEBUG MODE ENABLED: Waiting for debugger."
    [System.Diagnostics.Debugger]::Break()
    Write-Log "DEBUG MODE: Debugger attached."
}

# ==============================================================================
# SECTION 6 — SERVICE STOP SIGNAL
# ==============================================================================
# This kernel object allows the service wrapper to stop the script cleanly.
#
# IMPORTANT:
#   This is a *service-local* stop event (events.watcherStop), NOT the sacred
#   system-wide STOP (events.systemStop).
#
#   Because this is a named ManualReset event, it can remain signaled across
#   process lifetimes. If it is already signaled at startup, WaitAny() would
#   return immediately and the watcher would "start then instantly stop."
#
# Therefore:
#   - Detect stale signaled state at startup
#   - Clear it once (Reset)
#   - Log the corrective action (forensics)

$stopEvent = New-Object System.Threading.EventWaitHandle(
    $false,
    [System.Threading.EventResetMode]::ManualReset,
    $ServiceStopEventName
)

# ---- STALE STOP EVENT CLEAR (SERVICE-LOCAL ONLY) ----
try {
    if ($stopEvent.WaitOne(0)) {
        Write-Log "[WARN] STOP event was already signaled at startup. Clearing stale state: $ServiceStopEventName"
        $stopEvent.Reset() | Out-Null
        Write-Log "[WARN] STOP event stale state cleared. Watcher will proceed."
    }
} catch {
    # Failure to probe/reset is unusual but not fatal.
    # Worst case: watcher exits immediately and logs will show why.
    Write-Log "[WARN] Unable to probe/reset STOP event state: $($_.Exception.Message)"
}

# ==============================================================================
# SECTION 7 — INITIAL STATE RECONCILIATION
# ==============================================================================
# The watcher may start AFTER the VM is already running.
# We must align our internal state and flag file immediately.

$script:LastRunning = Test-Path -LiteralPath $LockDirPath

if ($script:LastRunning) {
    New-Item -ItemType File -Path $FlagFile -Force | Out-Null
    Write-Log "STARTUP STATE: VM already RUNNING."
}
else {
    Remove-Item -Path $FlagFile -ErrorAction SilentlyContinue
    Write-Log "STARTUP STATE: VM STOPPED."
}

# ==============================================================================
# SECTION 8 — THREAD-SAFE SIGNALING OBJECTS
# ==============================================================================
# These objects allow background threads to signal the main PowerShell loop
# WITHOUT executing PowerShell code themselves.

$fsQueue         = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$fsSignal        = New-Object System.Threading.AutoResetEvent($false)
$heartbeatSignal = New-Object System.Threading.AutoResetEvent($false)
$debounceSignal  = New-Object System.Threading.AutoResetEvent($false)

# NEW in v1.2.6:
# This signal wakes the main loop to re-check VM directory readiness without
# polling loops or Start-Sleep.
$vmDirRetrySignal = New-Object System.Threading.AutoResetEvent($false)

$debounceLock      = New-Object System.Object
$debounceScheduled = $false

# ==============================================================================
# SECTION 9 — C# BRIDGE (BACKGROUND THREAD SAFE)
# ==============================================================================
# FileSystemWatcher and timers run on background threads.
# PowerShell MUST NOT run there.
#
# This C# class:
#   - listens for filesystem events
#   - triggers heartbeats
#   - arms the debounce timer
#   - triggers VM directory readiness retry ticks
#   - ONLY signals kernel objects

try {
    Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Threading;

public sealed class VmGuardBridge : IDisposable
{
    private readonly FileSystemWatcher _fsw;
    private readonly ConcurrentQueue<string> _queue;
    private readonly AutoResetEvent _fsSignal;
    private readonly AutoResetEvent _heartbeatSignal;
    private readonly AutoResetEvent _debounceSignal;
    private readonly AutoResetEvent _vmDirRetrySignal;
    private readonly Timer _heartbeatTimer;
    private readonly Timer _debounceTimer;
    private readonly Timer _vmDirRetryTimer;

    public VmGuardBridge(
        string path,
        ConcurrentQueue<string> queue,
        AutoResetEvent fsSignal,
        AutoResetEvent heartbeatSignal,
        AutoResetEvent debounceSignal,
        AutoResetEvent vmDirRetrySignal,
        int heartbeatIntervalMs,
        int debounceMs,
        int vmDirRetryIntervalMs)
    {
        _queue = queue;
        _fsSignal = fsSignal;
        _heartbeatSignal = heartbeatSignal;
        _debounceSignal = debounceSignal;
        _vmDirRetrySignal = vmDirRetrySignal;

        // IMPORTANT:
        // FileSystemWatcher throws immediately if 'path' does not exist.
        // Therefore, Watcher MUST validate path readiness in PowerShell BEFORE
        // constructing this bridge.
        _fsw = new FileSystemWatcher(path, "*");
        _fsw.IncludeSubdirectories = true;
        _fsw.NotifyFilter =
            NotifyFilters.DirectoryName |
            NotifyFilters.FileName |
            NotifyFilters.LastWrite;

        _fsw.Created += OnFsEvent;
        _fsw.Deleted += OnFsEvent;
        _fsw.Changed += OnFsEvent;
        _fsw.Renamed += OnRenamed;
        _fsw.EnableRaisingEvents = true;

        _heartbeatTimer = new Timer(_ => _heartbeatSignal.Set(),
                                    null,
                                    heartbeatIntervalMs,
                                    heartbeatIntervalMs);

        _debounceTimer = new Timer(_ => _debounceSignal.Set(),
                                   null,
                                   Timeout.Infinite,
                                   Timeout.Infinite);

        // NEW:
        // VM directory readiness retry ticks.
        // This allows Watcher to stay alive deterministically if the VM storage
        // volume is not available at service start time.
        _vmDirRetryTimer = new Timer(_ => _vmDirRetrySignal.Set(),
                                     null,
                                     vmDirRetryIntervalMs,
                                     vmDirRetryIntervalMs);
    }

    private void OnFsEvent(object sender, FileSystemEventArgs e)
    {
        _queue.Enqueue(e.ChangeType + "|" + e.FullPath);
        _fsSignal.Set();
    }

    private void OnRenamed(object sender, RenamedEventArgs e)
    {
        _queue.Enqueue("Renamed|" + e.OldFullPath + " -> " + e.FullPath);
        _fsSignal.Set();
    }

    public void ArmDebounce(int ms)
    {
        _debounceTimer.Change(ms, Timeout.Infinite);
    }

    public void Dispose()
    {
        try { _heartbeatTimer.Dispose(); } catch {}
        try { _debounceTimer.Dispose(); } catch {}
        try { _vmDirRetryTimer.Dispose(); } catch {}
        try { _fsw.Dispose(); } catch {}
    }
}
"@
} catch {
    Write-Log "[FATAL] C# bridge compilation failed: $($_.Exception.Message)"
    Write-Log $Separator
    exit 1030
}

# ==============================================================================
# SECTION 10 — VM DIRECTORY READINESS HOLD (NO POLLING, NO SLEEP)
# ==============================================================================
# Services may start before storage volumes, mappings, or permissions settle.
#
# Prior behavior:
#   - Validate VM dir once
#   - Exit fatal if missing
#
# Problem:
#   - Procrun treats exit as "service died"
#   - SCM marks service failed even though the environment might become valid
#     seconds later (e.g. delayed disk / delayed mount)
#
# Solution (v1.2.6):
#   - If VM directory is missing at startup, enter a HOLD state.
#   - HOLD state is STOP-responsive and blocks on kernel objects only.
#   - A C# Timer wakes the loop to retry.
#
# This preserves the "no polling loop / no Start-Sleep" doctrine:
#   - We never busy-spin
#   - We never sleep blindly
#   - We wait on kernel objects (deterministic idle)

$VmDirRetryIntervalMs = 30000  # 30 seconds retry tick (operator-friendly)

if (-not (Test-Path -LiteralPath $VmDir)) {

    Write-Log "[ERROR] VM directory not available at startup: $VmDir"
    Write-Log "        Entering HOLD state. Will retry every $([int]($VmDirRetryIntervalMs/1000))s."
    Write-Log "        STOP event will terminate immediately: $ServiceStopEventName"

    $holdHandles = @(
        $stopEvent,
        $vmDirRetrySignal
    )

    while (-not (Test-Path -LiteralPath $VmDir)) {

        $holdIndex = [System.Threading.WaitHandle]::WaitAny($holdHandles)

        if ($holdIndex -eq 0) {
            Write-Log $Separator
            Write-Log "STOP SIGNAL RECEIVED during VM directory HOLD. Shutting down."
            Write-Log $Separator
            exit 0
        }

        # holdIndex 1 = retry tick
        Write-Log "[WARN] VM directory still not available: $VmDir"
    }

    Write-Log "[INFO] VM directory became available. Proceeding with initialization."
}

# ==============================================================================
# SECTION 11 — BRIDGE INITIALIZATION
# ==============================================================================
# IMPORTANT:
# Constructor arguments MUST be passed via -ArgumentList in PowerShell.

$bridge = $null

try {
    $bridge = New-Object VmGuardBridge -ArgumentList @(
        $VmDir,
        $fsQueue,
        $fsSignal,
        $heartbeatSignal,
        $debounceSignal,
        $vmDirRetrySignal,
        $HeartbeatIntervalMs,
        $StateStabilizationMs,
        $VmDirRetryIntervalMs
    )
} catch {
    Write-Log "[FATAL] Bridge initialization failed: $($_.Exception.Message)"
    Write-Log "        VmDir='$VmDir'  (exists=$(Test-Path -LiteralPath $VmDir))"
    Write-Log $Separator
    exit 1031
}

Write-Log "Watcher initialized. Awaiting events."

# ==============================================================================
# SECTION 12 — MAIN EVENT LOOP (ONLY PLACE POWERSHELL LOGIC RUNS)
# ==============================================================================
# This loop:
#   - blocks on kernel objects
#   - consumes zero CPU when idle
#   - is the ONLY place VM state is computed

$handles = @(
    $stopEvent,
    $fsSignal,
    $heartbeatSignal,
    $debounceSignal
)

while ($true) {

    $index = [System.Threading.WaitHandle]::WaitAny($handles)

    if ($index -eq 0) {
        Write-Log $Separator
        Write-Log "STOP SIGNAL RECEIVED. Shutting down."
        break
    }

    if ($index -eq 1) {
        $evt = $null
        while ($fsQueue.TryDequeue([ref]$evt)) {
            if ($VerboseFSW) {
                Write-Log "FSW DEBUG: $evt"
            }
        }

        [System.Threading.Monitor]::Enter($debounceLock)
        try {
            if (-not $debounceScheduled) {
                $debounceScheduled = $true
                $bridge.ArmDebounce($StateStabilizationMs)
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($debounceLock)
        }
    }

    if ($index -eq 2) {
        Write-Log "HEARTBEAT: Watcher alive. VM running=$($script:LastRunning)."
    }

    # ⚠️ VM STATE IS COMPUTED ONLY HERE ⚠️
    if ($index -eq 3) {

        $newState = Test-Path -LiteralPath $LockDirPath

        if ($newState -ne $script:LastRunning) {

            if ($newState) {
                New-Item -ItemType File -Path $FlagFile -Force | Out-Null
                Write-Log "VM STATE CHANGE: RUNNING."
            }
            else {
                Remove-Item -Path $FlagFile -ErrorAction SilentlyContinue
                Write-Log "VM STATE CHANGE: STOPPED."
            }

            $script:LastRunning = $newState
        }

        # ---- THREAD-SAFE RESET OF DEBOUNCE STATE ----
        [System.Threading.Monitor]::Enter($debounceLock)
        try {
            $debounceScheduled = $false
        }
        finally {
            [System.Threading.Monitor]::Exit($debounceLock)
        }
    }
}

# ==============================================================================
# SECTION 13 — CLEAN SHUTDOWN
# ==============================================================================
# Always dispose unmanaged resources before exiting.

try {
    if ($bridge) {
        $bridge.Dispose()
    }
    Write-Log "VMGuard Watcher exited cleanly."
    Write-Log $Separator
}
catch {
    Write-Log "ERROR during shutdown: $_"
    Write-Log $Separator
}

exit 0


