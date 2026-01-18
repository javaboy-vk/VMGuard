<#
================================================================================
 VMGuard – Guard Service – v1.15
================================================================================
 Script Name : vmguard-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-15
 Version     : 1.15

 PURPOSE
   Run as a LocalSystem Windows service under Apache Procrun and coordinate a
   clean, best-effort shutdown sequence for the Atlas VM by delegating any
   interactive/user-context work to a scheduled task.

 RESPONSIBILITIES
   1) Create/open a named kernel STOP event that Procrun STOP hooks can signal.
   2) Block efficiently waiting for the STOP event (no polling loops).
   3) On STOP, if the VM “running flag” exists, trigger the user-context
      scheduled task (best effort).
   4) NEVER hang or fail STOP: always exit quickly and return exit code 0.

 NON-RESPONSIBILITIES
   - This service does NOT directly shut down VMware or call vmrun.
   - This service does NOT attempt to guarantee the scheduled task completes.
   - This service does NOT perform long or blocking operations during STOP.

 LIFECYCLE CONTEXT
   - START: Procrun starts PowerShell with this script as StartParams.
   - STOP : Procrun STOP hook runs stop-signal.ps1 which signals a named kernel
           event. This script unblocks, performs best-effort actions, and exits.
   - HARD REQUIREMENT: STOP path must be bounded and non-blocking to prevent
           StopTimeout expirations and forced termination.

 v1.9 CHANGE
   - Harden StopEvent creation with an explicit security descriptor (DACL) so
     interactive tooling (dev harness) can OpenExisting() and signal STOP without
     "Access to the path is denied." This is required because the event is created
     by LocalSystem in Session 0 and default ACLs can block user tokens.
   - On "opened existing" stop event, attempt best-effort ACL normalization
     (log-only if it fails).

 v1.10 CHANGE
   - StopEvent lifecycle hardening:
       (1) If StopEvent is opened (already existed), Reset() it to avoid inheriting
           a previously-signaled ManualReset state that can cause "service started
           then stopped" immediately.
       (2) Add explicit WaitOne() boundary logging to prove whether Guard actually
           blocks and whether STOP is observed.
       (3) Probe current signaled state (WaitOne(0)) for high-signal diagnostics.

 v1.11 CHANGE
   - STOP hang elimination hardening:
       (1) Add explicit cleanup of PowerShell event subscribers + jobs at STOP
           completion, because Register-ObjectEvent / watchers can keep the host
           process alive even after the script reaches exit.
       (2) Dispose the kernel StopEvent handle explicitly (best-effort).
       (3) Replace soft "exit 0" termination with hard process termination
           ([System.Environment]::Exit(0)) after logging. This ensures Procrun/SCM
           observes immediate process exit even if dot-sourced modules left
           background runspace artifacts.

 v1.12 CHANGE
   - Dev-harness STOP reliability hardening:
       (1) Expand StopEvent DACL to include "Authenticated Users: Modify"
           in addition to "INTERACTIVE: Modify". This prevents OpenExisting()
           failures when the user token is not marked INTERACTIVE (elevated
           shells, remote sessions, dev tools, scheduled tasks, etc.).
       (2) Defensive StopEventName normalization to Global\* to guarantee
           cross-session visibility if a non-global name is ever configured.

 v1.13 CHANGE
   - Dev-harness STOP OpenExisting() access fix:
       (1) Upgrade "Authenticated Users" rights from Modify -> FullControl.
           Rationale: EventWaitHandle.OpenExisting() can require SYNCHRONIZE
           access in addition to Modify; some tokens still fail OpenExisting()
           with Modify-only DACL and throw "Access to the path is denied."

 v1.14 CHANGE
   - STOP alias plane materialization:
       (1) Define non-authoritative STOP alias names used by older tooling.
       (2) Materialize aliases as best-effort named kernel events to prevent
           "No handle of the given name exists" from OpenExisting() callers.
       (3) Dispose alias handles during termination hardening (best-effort).

 v1.15 CHANGE
   - Shutdown authority hardening:
       (1) Preserve user-context scheduled task as primary actor.
       (2) If scheduled task execution is not confirmed (non-zero exit or timeout),
           invoke a bounded service-context vmrun soft-stop fallback.
       (3) This mitigates shutdown races where Task Scheduler / user context is
           already in teardown and VMware suspends the VM.
================================================================================
#>

"RAW START HIT" | Out-File -FilePath "P:\Scripts\VMGuard\logs\guard-raw-start.txt" -Append

. "P:\Scripts\VMGuard\common\logging.ps1"
. "P:\Scripts\VMGuard\common\shutdown-actions.ps1"

# ==============================================================================
# 1. Configuration (Guard Contract)
# ==============================================================================
# Why we define these values explicitly:
# - This script is the "Guard contract" for the entire stop/start lifecycle.
# - If these values drift from install scripts / stop-signal scripts, STOP will
#   not be observed and Procrun will time out.
# - Keeping the contract at the top makes reviews and audits easy.
$FlagFile      = "P:\Scripts\VMGuard\flags\AtlasW19_running.flag"
$TaskName      = "VMGuard-Guard-User"

# v1.8 CHANGE:
# Guard-module shutdown actors.
# These belong to the same Guard module and are invoked directly.
#
# vm-smooth-shutdown.ps1:
#   - Primary smooth shutdown actor (user-capable context)
#   - Performs the actual VMware soft stop attempt
#
# stop-signal.ps1:
#   - Last-resort STOP release valve
#   - Must never fail
#
$SmoothShutdownScript = "P:\Scripts\VMGuard\guard\vm-smooth-shutdown.ps1"
$StopSignalScript    = "P:\Scripts\VMGuard\guard\vmguard-guard-stop-event-signal.ps1"

# v1.15 CHANGE:
# Service-context VMware authority fallback.
# This is invoked ONLY when the user-context scheduled task cannot be confirmed.
#
# IMPORTANT:
# - Path and VMX location MUST reflect your environment.
# - This fallback is bounded and best-effort; STOP must NEVER hang.
#
$VmrunExe = "P:\Apps\VMware\Workstation\vmrun.exe"
$AtlasVmx = "P:\VMs\AtlasW19\AtlasW19.vmx"

# IMPORTANT:
# Dedicated Guard stop event.
# This MUST match the StopEventName that stop-signal.ps1 signals.
# If this name changes, the service will never observe STOP and Procrun will
# eventually force-kill the process after StopTimeout.
$StopEventName = "Global\VMGuard_Guard_Stop"

# v1.14 CHANGE:
# STOP alias names for dev harness / tooling compatibility.
# These are NOT authoritative. They exist only to prevent
# "No handle of the given name exists" failures when tools
# reference older or alternate STOP names.
$StopEventAliases = @(
    "Global\VMGuard-STOP",
    "Global\VMGuard_Stop",
    "Global\VMGuardStop"
)

# v1.12 CHANGE:
# Defensive normalization to guarantee cross-session visibility even if a
# non-global name is ever configured.
if ($StopEventName -notmatch '^(?i)Global\\') {
    $StopEventName = "Global\$StopEventName"
    Write-Log "[WARN] StopEventName did not include Global\ prefix. Normalized to: $StopEventName"
}

# STOP hardening:
# Why we need this:
# - During host shutdown, Windows services are torn down in parallel.
# - Task Scheduler and the RPC stack can already be stopping when we are asked
#   to stop.
# - schtasks.exe can block indefinitely in those conditions.
# - STOP must NEVER hang. Therefore we hard-bound any external dependency wait.
$StopActionMaxWaitSeconds = 5

# ==============================================================================
# 2. Startup
# ==============================================================================
# Why we emit a startup separator:
# - Makes service restarts visually obvious in the log file.
# - Helps correlate Procrun logs with our script logs.
Write-Log "==========================================="
Write-Log "VMGuard Guard service started (LocalSystem)."
Write-Log ("Process: PID={0}, User={1}" -f $PID, [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Log "Contract:"
Write-Log "  FlagFile                 = $FlagFile"
Write-Log "  TaskName                 = $TaskName"
Write-Log "  StopEventName            = $StopEventName"
Write-Log "  StopActionMaxWaitSeconds = $StopActionMaxWaitSeconds"
Write-Log "  SmoothShutdownScript     = $SmoothShutdownScript"
Write-Log "  StopSignalScript         = $StopSignalScript"
Write-Log "  VmrunExe                 = $VmrunExe"
Write-Log "  AtlasVmx                 = $AtlasVmx"

# Why we explicitly log what we are about to do:
# - This service is designed to be mostly idle.
# - The next meaningful activity will only happen when STOP is signaled.
Write-Log "Waiting for STOP/shutdown signal..."

# ==============================================================================
# 3. Stop Event Creation (Named Kernel Event)
# ==============================================================================
# Why this exists:
# - Procrun STOP hook (stop-signal.ps1) signals this event.
# - The main thread blocks on it, so we do not need timers or polling.
# - This is the most reliable pattern for PowerShell services under Procrun:
#   no timer jobs, no background runspaces, no fragile parsing of StopParams.
#
# Why ManualReset:
# - The STOP event is a one-way latch: once STOP is requested, we should never
#   "un-stop".
# - ManualReset keeps the event signaled until the process exits.
#
# v1.9 CHANGE (SECURITY):
# - Create with explicit ACL so non-service tools can OpenExisting() and Set().
# - Without this, LocalSystem-created kernel objects can deny user tokens.
#
# ACL intent:
#   - LocalSystem: FullControl
#   - Administrators: FullControl
#   - Interactive Users: Modify (signal is sufficient)
#
$createdNew = $false
$stopEvent  = $null
$eventSec   = $null

try {
    $eventSec = New-Object System.Security.AccessControl.EventWaitHandleSecurity

    # SIDs (avoid name resolution variability across locales/domains)
    $sidLocalSystem   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")       # LOCAL SYSTEM
    $sidAdmins        = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")   # BUILTIN\Administrators
    $sidInteractive   = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-4")        # INTERACTIVE
    $sidAuthUsers     = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")       # Authenticated Users

    $ruleSystem = New-Object System.Security.AccessControl.EventWaitHandleAccessRule(
        $sidLocalSystem,
        [System.Security.AccessControl.EventWaitHandleRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ruleAdmins = New-Object System.Security.AccessControl.EventWaitHandleAccessRule(
        $sidAdmins,
        [System.Security.AccessControl.EventWaitHandleRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ruleInteractive = New-Object System.Security.AccessControl.EventWaitHandleAccessRule(
        $sidInteractive,
        [System.Security.AccessControl.EventWaitHandleRights]::Modify,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    # v1.12 CHANGE:
    # Covers authenticated user tokens that are not marked INTERACTIVE
    # (elevated shells, remote sessions, dev tools, scheduled tasks, etc.)
    #
    # v1.13 CHANGE:
    # Upgrade Authenticated Users from Modify -> FullControl because
    # OpenExisting() can require SYNCHRONIZE access which is not reliably
    # granted by Modify-only across all token types.
    $ruleAuthUsers = New-Object System.Security.AccessControl.EventWaitHandleAccessRule(
        $sidAuthUsers,
        [System.Security.AccessControl.EventWaitHandleRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    $null = $eventSec.AddAccessRule($ruleSystem)
    $null = $eventSec.AddAccessRule($ruleAdmins)
    $null = $eventSec.AddAccessRule($ruleInteractive)
    $null = $eventSec.AddAccessRule($ruleAuthUsers)

    $stopEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $StopEventName,
        [ref]$createdNew,
        $eventSec
    )
}
catch {
    # Best-effort: if ACL creation fails for any reason, fall back to default creation.
    Write-Log "[WARN] Failed to create StopEvent with explicit ACL. Falling back to default event creation. Details: $($_.Exception.Message)"

    $createdNew = $false
    $stopEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $StopEventName,
        [ref]$createdNew
    )
}

# Why we log created vs opened:
# - If the event is always "opened", something else created it earlier.
# - If it is always "created", that is normal for a fresh boot.
# - This helps diagnose naming mismatches or stale objects.
if ($createdNew) {
    Write-Log "Stop event created: $StopEventName (ACL: LocalSystem=Full, Admins=Full, Interactive=Modify, AuthUsers=Full)"
} else {
    Write-Log "Stop event opened (already existed): $StopEventName"

    # v1.9 CHANGE:
    # Best-effort ACL normalization for cases where an older instance created a
    # restrictive DACL (can cause dev harness OpenExisting() -> Access denied).
    #
    # IMPORTANT:
    # - If we do not have rights to change ACL, we log and proceed (never fail START).
    # - This does not block STOP; it only improves testability and tooling.
    if ($null -ne $eventSec)
    {
        try
        {
            $stopEvent.SetAccessControl($eventSec)
            Write-Log "Stop event ACL normalized (best-effort)."
        }
        catch
        {
            Write-Log "[WARN] Unable to normalize Stop event ACL (best-effort). Details: $($_.Exception.Message)"
        }
    }

    # v1.10 CHANGE:
    # ManualReset events can remain signaled if a prior instance set STOP and then
    # exited. If we inherit a signaled state, WaitOne() returns immediately and
    # the service will "start then stop", which is confusing and incorrect.
    #
    # Best-effort: Reset() the event when we OPEN an existing instance to ensure
    # we begin in a known non-signaled state.
    try {
        $stopEvent.Reset()
        Write-Log "Stop event reset to non-signaled state (opened-existing hardening)."
    }
    catch {
        Write-Log "[WARN] Unable to reset Stop event (best-effort). Details: $($_.Exception.Message)"
    }
}

# v1.10 CHANGE:
# Probe current signaled state for high-signal diagnostics.
try {
    $signaledNow = $stopEvent.WaitOne(0)
    Write-Log ("Stop event probe: SignaledNow={0}" -f $signaledNow)
} catch {
    Write-Log "[WARN] Unable to probe Stop event signaled state (best-effort)."
}

# ==============================================================================
# 3.1 STOP Alias Event Materialization (v1.14)
# ==============================================================================
# Why this exists:
# - Dev harness / tools may attempt OpenExisting() using older or alternate names.
# - Kernel objects are name-bound; if the name does not exist, OpenExisting fails.
# - We materialize best-effort aliases that all point to the same logical STOP plane.
#
# Design rules:
# - Authoritative contract remains: $StopEventName
# - Aliases are compatibility only.
# - Failure to create any alias MUST NOT affect Guard start.

$aliasEvents = @()

foreach ($alias in $StopEventAliases) {

    if ($alias -ieq $StopEventName) { continue }

    try {
        $aliasCreated = $false

        $aliasEvent = New-Object System.Threading.EventWaitHandle(
            $false,
            [System.Threading.EventResetMode]::ManualReset,
            $alias,
            [ref]$aliasCreated,
            $eventSec
        )

        if ($aliasCreated) {
            Write-Log "Stop event alias created: $alias"
        } else {
            Write-Log "Stop event alias opened (already existed): $alias"
        }

        $aliasEvents += $aliasEvent
    }
    catch {
        Write-Log "[WARN] Unable to create/open Stop event alias '$alias'. Details: $($_.Exception.Message)"
    }
}

# ==============================================================================
# 4. Wait for STOP Signal
# ==============================================================================
# Why we block here:
# - This is the "idle" state of the Guard service.
# - Blocking consumes no CPU.
# - When STOP is signaled, WaitOne() returns immediately and we handle STOP.
#
# Important shutdown behavior:
# - If the OS force-terminates the process (rare), we may not run STOP logic.
# - Under normal Procrun STOP, stop-signal.ps1 sets the event and we continue.
Write-Log "Guard entering STOP wait (WaitOne)..."
[void]$stopEvent.WaitOne()
Write-Log "Guard released from STOP wait (WaitOne returned)."
"RAW AFTER EVENT WAIT" | Out-File "P:\Scripts\VMGuard\logs\guard-raw.txt" -Append

# ==============================================================================
# 5. STOP Handler (Best-Effort, Bounded, Never Hang)
# ==============================================================================
Write-Log "==========================================="

# Why we timestamp STOP:
# - Procrun has its own StopTimeout clock.
# - We want to prove (in our logs) that we exit well before that limit.
$stopStart = Get-Date
Write-Log "Stop/shutdown signal received."
Write-Log "STOP handler started at $stopStart"

# v1.7 CHANGE:
# The Guard is NOT a VM watcher. These hooks provide bounded, auditable
# extension points around the shutdown transaction only.
Invoke-OnSystemShutdownDetected

try {
    # Why we gate behavior on the flag file:
    # - The Guard must never "guess" if Atlas is running using VMware APIs.
    # - The watcher/VM instrumentation owns that truth via the running flag.
    # - If the flag is absent, we do nothing and exit quickly.
    if (Test-Path $FlagFile) {
        Write-Log "Atlas flag is present -> attempting smooth shutdown via scheduled task: '$TaskName'"

        # v1.7 CHANGE:
        # Pre-shutdown hook (bounded only). This is NOT a place for loops or waits.
        Invoke-BeforeVmShutdown

        # v1.8 CHANGE:
        # Primary smooth shutdown actor.
        # This runs vm-smooth-shutdown.ps1 as a bounded external process.
        # The Guard does NOT wait indefinitely and does NOT care about success.
        #
        try {
            $p = Start-Process -FilePath "powershell.exe" `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SmoothShutdownScript`"" `
                -NoNewWindow -PassThru

            $exited = $false
            try {
                $null = Wait-Process -Id $p.Id -Timeout $StopActionMaxWaitSeconds
                $exited = $true
            }
            catch {
                $exited = $false
            }

            if ($exited) {
                Write-Log "vm-smooth-shutdown.ps1 exited. ExitCode=$($p.ExitCode)"
            }
            else {
                Write-Log "[WARN] vm-smooth-shutdown.ps1 did not exit within ${StopActionMaxWaitSeconds}s. Killing process and continuing."
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        catch {
            Write-Log "[ERROR] Failed to invoke vm-smooth-shutdown.ps1. Details: $($_.Exception.Message)"
        }

        # CRITICAL DESIGN RULE:
        # The scheduled task is executed in a user context (interactive session),
        # because LocalSystem services are not reliable for VMware UI / user-space
        # operations and because the user context is where VMware interaction is
        # permitted and stable.
        #
        # WHY WE DO NOT WAIT INDEFINITELY:
        # - During host shutdown, Task Scheduler and RPC may already be shutting down.
        # - schtasks.exe /run may hang while trying to contact those services.
        # - If we use Start-Process -Wait, we can block STOP until Procrun kills us.
        # - Therefore: start schtasks, wait a small bounded time, then abandon.
        try {
            $p = Start-Process -FilePath "schtasks.exe" `
                -ArgumentList @("/run", "/tn", $TaskName) `
                -NoNewWindow -PassThru

            # Why we use a bounded wait:
            # - We want quick feedback when things work normally.
            # - We also want a guaranteed exit path when Windows is tearing down.
            $exited = $false
            try {
                $null = Wait-Process -Id $p.Id -Timeout $StopActionMaxWaitSeconds
                $exited = $true
            }
            catch {
                $exited = $false
            }

            if ($exited) {
                # Why logging exit code matters:
                # - schtasks.exe returns non-zero when the task is missing, disabled,
                #   or cannot run (permissions / no user session / scheduler issues).
                Write-Log "schtasks exited quickly. ExitCode=$($p.ExitCode)"

                if ($p.ExitCode -ne 0) {
                    Write-Log "[WARN] schtasks returned non-zero. Verify the task exists and can run under a logged-on user context."
                } else {
                    Write-Log "Scheduled task triggered successfully."
                }
            }
            else {
                # Why we kill the helper:
                # - Not because we care about schtasks.exe.
                # - Because we MUST prevent STOP from hanging.
                # - The Guard's contract is to exit quickly no matter what.
                Write-Log "[WARN] schtasks did not exit within ${StopActionMaxWaitSeconds}s (shutdown/RPC likely in teardown). Killing helper and continuing."
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        catch {
            # Best-effort failure:
            # - We log and exit 0 regardless.
            # - STOP must never fail the service shutdown sequence.
            Write-Log "[ERROR] Failed to invoke scheduled task. Details: $($_.Exception.Message)"
        }

        # v1.15 CHANGE:
        # Service-context VMware authority fallback.
        #
        # Trigger conditions:
        # - schtasks did not exit within the bounded wait window, OR
        # - schtasks exited but returned non-zero (task missing/disabled/failed).
        #
        # Rationale:
        # - Late in host shutdown, Task Scheduler / RPC / user session can be
        #   partially torn down.
        # - In those cases, VMware may suspend Atlas before user-context actors run.
        # - This fallback attempts a bounded vmrun soft stop directly as LocalSystem.
        #
        # HARD REQUIREMENT:
        # - Must be best-effort, bounded, and must never block STOP exit.
        #
        if (-not $exited -or ($exited -and $p.ExitCode -ne 0)) {

            Write-Log "[WARN] Scheduled task shutdown not confirmed. Engaging service-context vmrun fallback."

            try {
                if (-not (Test-Path $VmrunExe)) {
                    Write-Log "[WARN] vmrun.exe not found at configured path: $VmrunExe"
                }
                elseif (-not (Test-Path $AtlasVmx)) {
                    Write-Log "[WARN] Atlas VMX not found at configured path: $AtlasVmx"
                }
                else {
                    $vp = Start-Process -FilePath $VmrunExe `
                        -ArgumentList @("-T","ws","stop",$AtlasVmx,"soft") `
                        -NoNewWindow -PassThru

                    $vExited = $false
                    try {
                        $null = Wait-Process -Id $vp.Id -Timeout 15
                        $vExited = $true
                    }
                    catch {
                        $vExited = $false
                    }

                    if ($vExited) {
                        Write-Log "Service-context vmrun exited. ExitCode=$($vp.ExitCode)"
                    }
                    else {
                        Write-Log "[WARN] Service-context vmrun did not exit within 15s. Killing helper."
                        try { Stop-Process -Id $vp.Id -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            }
            catch {
                Write-Log "[ERROR] Service-context vmrun fallback failed. Details: $($_.Exception.Message)"
            }
        }

        # v1.7 CHANGE:
        # Post-decision hook. Attempted=$true means we attempted to trigger shutdown.
        Invoke-AfterVmShutdownAttempt -Attempted $true
    }
    else {
        Write-Log "Atlas flag is NOT present -> Atlas VM not considered running. No action required."

        # v1.7 CHANGE:
        # Post-decision hook. Attempted=$false means no action was necessary.
        Invoke-AfterVmShutdownAttempt -Attempted $false
    }
}
catch {
    # Absolute last line of defense:
    # - Any unexpected exception must be contained and logged.
    # - Exit code must still be 0.
    Write-Log "[ERROR] Unexpected exception in STOP handler. Details: $($_.Exception.Message)"
}
finally {
    # Why we always log STOP duration:
    # - This provides objective evidence that the service is well-behaved.
    # - If STOP duration creeps up, we will see it immediately in the logs.
    $stopEnd = Get-Date
    $durSec = ($stopEnd - $stopStart).TotalSeconds
    Write-Log ("STOP handler finished at {0} (duration seconds: {1:n2})" -f $stopEnd, $durSec)

    # Why we log exit:
    # - Confirms the process is about to return to Procrun.
    # - If Procrun still times out, the hang is outside of our script logic.
    Write-Log "VMGuard Guard service exiting cleanly."

    # v1.8 CHANGE:
    # Absolute last-resort failsafe.
    # Even though Procrun STOP already triggered stop-signal.ps1,
    # we issue one final best-effort attempt before exit.
    #
    try {
        & "powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $StopSignalScript
    }
    catch {
        # Never block or fail STOP on failsafe errors.
    }

    # v1.7 CHANGE:
    # Final bounded hook before process termination.
    Invoke-OnGuardExit

    # ==============================================================================
    # 5.6 Termination Hardening (Eliminate Procrun StopTimeout Hangs)
    # ==============================================================================
    # Why this exists:
    # - In PowerShell, background event subscriptions (Register-ObjectEvent),
    #   watcher objects, and lingering jobs can keep the host process alive even
    #   after the script reaches "exit".
    # - Procrun will then wait until StopTimeout and only then tear down the process,
    #   which appears as a "hung stop" in Services.msc.
    #
    # Design intent:
    # - Best-effort cleanup (never throw, never block).
    # - Then force process termination to guarantee immediate stop completion.
    try {
        # Clean up any event subscribers created by dot-sourced modules (best-effort).
        $subs = @(Get-EventSubscriber -ErrorAction SilentlyContinue)
        if ($subs.Count -gt 0) {
            Write-Log ("Termination hardening: Unregistering {0} event subscriber(s)." -f $subs.Count)
            foreach ($s in $subs) {
                try { Unregister-Event -SubscriptionId $s.SubscriptionId -Force -ErrorAction SilentlyContinue } catch {}
            }
        } else {
            Write-Log "Termination hardening: No event subscribers found."
        }

        # Clean up any lingering jobs (best-effort).
        $jobs = @(Get-Job -ErrorAction SilentlyContinue)
        if ($jobs.Count -gt 0) {
            Write-Log ("Termination hardening: Removing {0} job(s)." -f $jobs.Count)
            foreach ($j in $jobs) {
                try { Stop-Job -Id $j.Id -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Job -Id $j.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        } else {
            Write-Log "Termination hardening: No jobs found."
        }

        # Dispose the StopEvent handle explicitly (best-effort).
        if ($null -ne $stopEvent) {
            try { $stopEvent.Dispose() } catch {}
            $stopEvent = $null
            Write-Log "Termination hardening: Stop event handle disposed."
        }

        # v1.14 CHANGE:
        # Dispose STOP alias event handles (best-effort).
        if ($null -ne $aliasEvents) {
            foreach ($e in $aliasEvents) {
                try { $e.Dispose() } catch {}
            }
            Write-Log "Termination hardening: Stop event alias handles disposed."
        }

        # Final GC hint (best-effort; do not block on it).
        try { [System.GC]::Collect() } catch {}
        try { [System.GC]::WaitForPendingFinalizers() } catch {}

        Write-Log "Termination hardening: Forcing process exit with code 0."
    }
    catch {
        # Never block or fail STOP due to cleanup logic.
    }

    # HARD REQUIREMENT:
    # Force the PowerShell host process to terminate now.
    [System.Environment]::Exit(0)
}

# ==============================================================================
# END OF FILE
# ==============================================================================
