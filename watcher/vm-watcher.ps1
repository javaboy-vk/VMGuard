<#
================================================================================
 VMGuard – VM Watcher Service
================================================================================

 Author: javaboy-vk
 Version: 1.1
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
# SECTION 1 — CONFIGURATION
# ==============================================================================
# This section contains ALL tunable values.
# A junior developer should ONLY modify this section when adapting the script.

$VmName = "AtlasW19"

# Directory where VMware stores the VM files
$VmDir  = "P:\VMs\AtlasW19"

# VMware runtime indicator:
# IMPORTANT: This is a DIRECTORY, not a file.
$LockDirPath = Join-Path $VmDir "$VmName.vmdk.lck"

# VMGuard base directory
$BaseDir  = "P:\Scripts\VMGuard"

# Single shared log file used by all VMGuard components
$LogFile  = "$BaseDir\logs\vmguard.log"

# Flag file created when VM is running
$FlagFile = "$BaseDir\flags\${VmName}_running.flag"

# Named Windows kernel event used by the service wrapper to stop this script
$ServiceStopEventName = "Global\VMGuard_Watcher_Stop"

# Windows Application Event Log source name
$EventSource = "VMGuard-Watcher"

# Heartbeat:
# Periodic log entry proving the watcher is alive
$HeartbeatMinutes    = 5
$HeartbeatIntervalMs = $HeartbeatMinutes * 60 * 1000

# Debounce window:
# Time to wait after filesystem activity before evaluating VM state
$StateStabilizationMs = 1500

# --------------------------------------------------------------------------
# BOOTSTRAP PROOF-OF-LIFE
# This MUST run before logging.ps1 is loaded.
# If this does not appear in the log file, PowerShell never executed.
# --------------------------------------------------------------------------
try {
    New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
    Add-Content -Path $LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 
                    - BOOTSTRAP: VMGuard Watcher entered PowerShell."
} catch {}

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

. "$BaseDir\common\logging.ps1"

# Ensure required directories exist
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile)  | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $FlagFile) | Out-Null

# ==============================================================================
# SECTION 4 — STARTUP LOGGING
# ==============================================================================
# A visible separator helps operators visually identify restarts.

Write-Log "==========================================="
Write-Log "VMGuard Watcher starting (SYSTEM context)."
Write-Log "VM directory           : $VmDir"
Write-Log "Runtime lock directory : $LockDirPath"
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

$stopEvent = New-Object System.Threading.EventWaitHandle(
    $false,
    [System.Threading.EventResetMode]::ManualReset,
    $ServiceStopEventName
)

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
#   - ONLY signals kernel objects

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
    private readonly Timer _heartbeatTimer;
    private readonly Timer _debounceTimer;

    public VmGuardBridge(
        string path,
        ConcurrentQueue<string> queue,
        AutoResetEvent fsSignal,
        AutoResetEvent heartbeatSignal,
        AutoResetEvent debounceSignal,
        int heartbeatIntervalMs,
        int debounceMs)
    {
        _queue = queue;
        _fsSignal = fsSignal;
        _heartbeatSignal = heartbeatSignal;
        _debounceSignal = debounceSignal;

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
        try { _fsw.Dispose(); } catch {}
    }
}
"@

# ==============================================================================
# SECTION 10 — BRIDGE INITIALIZATION
# ==============================================================================
# IMPORTANT:
# Constructor arguments MUST be passed via -ArgumentList in PowerShell.

$bridge = New-Object VmGuardBridge -ArgumentList @(
    $VmDir,
    $fsQueue,
    $fsSignal,
    $heartbeatSignal,
    $debounceSignal,
    $HeartbeatIntervalMs,
    $StateStabilizationMs
)

Write-Log "Watcher initialized. Awaiting events."

# ==============================================================================
# SECTION 11 — MAIN EVENT LOOP (ONLY PLACE POWERSHELL LOGIC RUNS)
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
# SECTION 12 — CLEAN SHUTDOWN
# ==============================================================================
# Always dispose unmanaged resources before exiting.

try {
    $bridge.Dispose()
    Write-Log "VMGuard Watcher exited cleanly."
}
catch {
    Write-Log "ERROR during shutdown: $_"
}

exit 0
