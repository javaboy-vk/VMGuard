<#
================================================================================
 VMGuard – Guard Service – v1.18
================================================================================
 Script Name : vmguard-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 1.18

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

 v1.16 CHANGE
   - STOP actor wait is now stderr-silent and non-fatal:
       * Wait-Process timeout no longer emits error records to procrun stderr
       * Timeouts log WARN, force-kill the actor, and continue convergence
       * Start-Process uses explicit Windows PowerShell path (no PATH ambiguity)

 v1.18 CHANGE
   - Config discovery now includes \conf\* (canonical repo layout)

 v1.17 CHANGE
   - Portability + service survivability hardening:
       * Root-anchored paths derived from script location (no hard-coded P:\...).
       * Optional config overlay from env.properties + settings.json (best-effort).
       * Logging can NEVER terminate Guard: Write-Log wrapped to degrade safely.
       * Raw debug Out-File writes are best-effort and never fatal.
       * Stop-signal invocation uses explicit Windows PowerShell path.
================================================================================
#>

# ==============================================================================
# 0. Root anchoring + optional config overlay (best-effort)
# ==============================================================================
# Portability doctrine:
# - VMGuard root is anchored from this script's directory.
# - Optional config files can override environment-specific paths.
#
# Supported config locations (first match wins):
#   - <VMGuardRoot>\conf\env.properties
#   - <VMGuardRoot>\config\env.properties
#   - <VMGuardRoot>\env.properties
#   - <VMGuardRoot>\conf\settings.json
#   - <VMGuardRoot>\config\settings.json
#   - <VMGuardRoot>\settings.json
#
# This service MUST remain deterministic even if config files are missing or malformed.

function Import-VMGEnvProperties {
    param([Parameter(Mandatory)][string]$Path)

    $props = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith(';')) { continue }

        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }

        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if ($k.Length -gt 0) { $props[$k] = $v }
    }
    return $props
}

function Get-VMGJsonPathValue {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    $cur = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if (-not $cur.Contains($seg)) { return $null }
            $cur = $cur[$seg]
        } else {
            $prop = $cur.PSObject.Properties[$seg]
            if ($null -eq $prop) { return $null }
            $cur = $prop.Value
        }
    }
    return $cur
}

function Get-VMGSettingFirst {
    param(
        [object]$SettingsObject,
        [hashtable]$EnvProps,
        [string[]]$JsonCandidates,
        [string[]]$EnvCandidates
    )

    foreach ($p in $JsonCandidates) {
        if ($SettingsObject) {
            $v = Get-VMGJsonPathValue -Object $SettingsObject -Path $p
            if ($null -ne $v -and "$v".Trim().Length -gt 0) { return "$v".Trim() }
        }
    }

    foreach ($k in $EnvCandidates) {
        if ($EnvProps -and $EnvProps.ContainsKey($k)) {
            $v = "$($EnvProps[$k])".Trim()
            if ($v.Length -gt 0) { return $v }
        }
    }

    return $null
}

function Resolve-VMGMaybeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $Root $PathValue)
}

# Determine VMGuard root: <this>\guard\vmguard-service.ps1 => root = <this>\..
$BaseDir = $null
try {
    $BaseDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
} catch {
    # Absolute last fallback: do not throw; keep script alive.
    $BaseDir = (Split-Path -Parent $PSScriptRoot)
}

$envPropsPathCandidates = @(
    (Join-Path $BaseDir 'conf\env.properties'),
    (Join-Path $BaseDir 'config\env.properties'),
    (Join-Path $BaseDir 'env.properties')
)
$settingsJsonPathCandidates = @(
    (Join-Path $BaseDir 'conf\settings.json'),
    (Join-Path $BaseDir 'config\settings.json'),
    (Join-Path $BaseDir 'settings.json')
)

$EnvPropsPath = $envPropsPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$SettingsPath = $settingsJsonPathCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$EnvProps = @{}
if ($EnvPropsPath) {
    try { $EnvProps = Import-VMGEnvProperties -Path $EnvPropsPath } catch { $EnvProps = @{} }
}

$Settings = $null
if ($SettingsPath) {
    try { $Settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json } catch { $Settings = $null }
}

# Windows PowerShell (service-safe; avoid PATH ambiguity)
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# ==============================================================================
# 0.1 Module loading (root-anchored)
# ==============================================================================
. (Join-Path $BaseDir "common\logging.ps1")
. (Join-Path $BaseDir "common\shutdown-actions.ps1")

# ==============================================================================
# 0.2 Logging hardening shim (logging must NEVER terminate Guard)
# ==============================================================================
# We have observed cases where Write-Log emits a Write-Error when file logging
# degrades ("Stream was not readable"), which is fatal under Procrun/SCM.
#
# Guard contract:
# - Logging may degrade.
# - Logging must never throw or emit Write-Error in a way that crashes the service.
try {
    $cmd = Get-Command Write-Log -CommandType Function -ErrorAction SilentlyContinue
    if ($cmd) { $script:VMG_WriteLog_Orig = $cmd.ScriptBlock }

    Remove-Item function:Write-Log -Force -ErrorAction SilentlyContinue

    function Write-Log {
        param(
            [Parameter(Mandatory)][string]$Message,
            [string]$Level = "Information"
        )

        try {
            if ($script:VMG_WriteLog_Orig) {
                & $script:VMG_WriteLog_Orig -Message $Message -Level $Level
            } else {
                Write-Host ("{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
            }
        }
        catch {
            # Absolute last resort: never throw, never Write-Error.
            Write-Host ("[VMGuard][LOGGING-DEGRADED] {0}" -f $Message)
        }
    }
} catch {
    function Write-Log {
        param([string]$Message,[string]$Level="Information")
        Write-Host ("[VMGuard][LOGGING-DEGRADED] {0}" -f $Message)
    }
}

# Best-effort raw debug markers (never fatal)
try {
    $rawStart = Join-Path $BaseDir "logs\guard-raw-start.txt"
    "RAW START HIT" | Out-File -FilePath $rawStart -Append -ErrorAction SilentlyContinue
} catch {}

# ==============================================================================
# 1. Configuration (Guard Contract)
# ==============================================================================
# Why we define these values explicitly:
# - This script is the "Guard contract" for the entire stop/start lifecycle.
# - If these values drift from install scripts / stop-signal scripts, STOP will
#   not be observed and Procrun will time out.
# - Keeping the contract at the top makes reviews and audits easy.

# VM identity
$VmName = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vm.target.name','vm.name','vmName','atlasVmName','targetVmName') `
    -EnvCandidates  @('ATLAS_VM_NAME','VM_NAME','VMGUARD_VM_NAME','TARGET_VM_NAME')
if (-not $VmName) { $VmName = 'AtlasW19' }

# Flag file (watcher-owned truth)
$FlagFile = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vmguard.guard.flagFile','guard.flagFile','flagFile') `
    -EnvCandidates  @('VMGUARD_FLAGFILE','GUARD_FLAGFILE','FLAGFILE')

if ($FlagFile) { $FlagFile = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $FlagFile }
else { $FlagFile = Join-Path $BaseDir ("flags\{0}_running.flag" -f $VmName) }

# Scheduled task (user plane)
$TaskName = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vmguard.guard.taskName','guard.taskName','taskName') `
    -EnvCandidates  @('VMGUARD_TASKNAME','GUARD_TASKNAME','TASKNAME')

if (-not $TaskName) { $TaskName = "VMGuard-Guard-User" }

# Guard-module shutdown actors.
$SmoothShutdownScript = Join-Path $BaseDir "guard\vm-smooth-shutdown.ps1"
$StopSignalScript    = Join-Path $BaseDir "guard\vmguard-guard-stop-event-signal.ps1"

# v1.15 CHANGE:
# Service-context VMware authority fallback.
$VmrunExe = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vmware.vmrunExe','vmguard.vmware.vmrunExe','vmrunExe') `
    -EnvCandidates  @('VMRUN_EXE','VMWARE_VMRUN_EXE','VMGUARD_VMRUN_EXE')

if ($VmrunExe) { $VmrunExe = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $VmrunExe }
else { $VmrunExe = "P:\Apps\VMware\Workstation\vmrun.exe" }

$AtlasVmx = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vmware.atlasVmx','vm.atlas.vmx','atlasVmx') `
    -EnvCandidates  @('ATLAS_VMX','VMGUARD_ATLAS_VMX')

if ($AtlasVmx) { $AtlasVmx = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $AtlasVmx }
else { $AtlasVmx = "P:\VMs\AtlasW19\AtlasW19.vmx" }

# Dedicated Guard stop event (authoritative)
$StopEventName = Get-VMGSettingFirst `
    -SettingsObject $Settings `
    -EnvProps $EnvProps `
    -JsonCandidates @('vmguard.stop.eventName','stop.eventName','StopEventName') `
    -EnvCandidates  @('VMGUARD_STOP_EVENT','STOP_EVENT_NAME')

if (-not $StopEventName) { $StopEventName = "Global\VMGuard_Guard_Stop" }

# v1.14 CHANGE:
# STOP alias names for dev harness / tooling compatibility.
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
$StopActionMaxWaitSeconds = 5

# ==============================================================================
# 2. Startup
# ==============================================================================
Write-Log "==========================================="
Write-Log "VMGuard Guard service started (LocalSystem)."
Write-Log ("Process: PID={0}, User={1}" -f $PID, [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Log "Contract:"
Write-Log "  BaseDir                  = $BaseDir"
Write-Log "  VmName                   = $VmName"
Write-Log "  FlagFile                 = $FlagFile"
Write-Log "  TaskName                 = $TaskName"
Write-Log "  StopEventName            = $StopEventName"
Write-Log "  StopActionMaxWaitSeconds = $StopActionMaxWaitSeconds"
Write-Log "  SmoothShutdownScript     = $SmoothShutdownScript"
Write-Log "  StopSignalScript         = $StopSignalScript"
Write-Log "  VmrunExe                 = $VmrunExe"
Write-Log "  AtlasVmx                 = $AtlasVmx"
Write-Log "Waiting for STOP/shutdown signal..."

# ==============================================================================
# 3. Stop Event Creation (Named Kernel Event)
# ==============================================================================
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

    # v1.12/v1.13 CHANGE:
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
    Write-Log "[WARN] Failed to create StopEvent with explicit ACL. Falling back to default event creation. Details: $($_.Exception.Message)"

    $createdNew = $false
    $stopEvent = New-Object System.Threading.EventWaitHandle(
        $false,
        [System.Threading.EventResetMode]::ManualReset,
        $StopEventName,
        [ref]$createdNew
    )
}

if ($createdNew) {
    Write-Log "Stop event created: $StopEventName (ACL: LocalSystem=Full, Admins=Full, Interactive=Modify, AuthUsers=Full)"
} else {
    Write-Log "Stop event opened (already existed): $StopEventName"

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

    try {
        $stopEvent.Reset()
        Write-Log "Stop event reset to non-signaled state (opened-existing hardening)."
    }
    catch {
        Write-Log "[WARN] Unable to reset Stop event (best-effort). Details: $($_.Exception.Message)"
    }
}

try {
    $signaledNow = $stopEvent.WaitOne(0)
    Write-Log ("Stop event probe: SignaledNow={0}" -f $signaledNow)
} catch {
    Write-Log "[WARN] Unable to probe Stop event signaled state (best-effort)."
}

# ==============================================================================
# 3.1 STOP Alias Event Materialization (v1.14)
# ==============================================================================
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
Write-Log "Guard entering STOP wait (WaitOne)..."
[void]$stopEvent.WaitOne()
Write-Log "Guard released from STOP wait (WaitOne returned)."

try {
    $rawAfter = Join-Path $BaseDir "logs\guard-raw.txt"
    "RAW AFTER EVENT WAIT" | Out-File -FilePath $rawAfter -Append -ErrorAction SilentlyContinue
} catch {}

# ==============================================================================
# 5. STOP Handler (Best-Effort, Bounded, Never Hang)
# ==============================================================================
Write-Log "==========================================="

$stopStart = Get-Date
Write-Log "Stop/shutdown signal received."
Write-Log "STOP handler started at $stopStart"

Invoke-OnSystemShutdownDetected

# State for v1.15 fallback decision (must remain defined even on exceptions)
$taskExited    = $false
$taskExitCode  = $null

try {
    if (Test-Path $FlagFile) {
        Write-Log "Atlas flag is present -> attempting smooth shutdown via scheduled task: '$TaskName'"

        Invoke-BeforeVmShutdown

        # ==========================================================================
        # 5.1 Primary smooth shutdown actor (bounded external process)
        # ==========================================================================
        try {
            $pSmooth = Start-Process -FilePath $PsExe `
                -ArgumentList @(
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-File", $SmoothShutdownScript
                ) `
                -NoNewWindow -PassThru

            try {
                $null = Wait-Process -Id $pSmooth.Id -Timeout $StopActionMaxWaitSeconds -ErrorAction Stop
                Write-Log "vm-smooth-shutdown.ps1 exited. ExitCode=$($pSmooth.ExitCode)"
            }
            catch {
                Write-Log "[WARN] vm-smooth-shutdown.ps1 did not exit within ${StopActionMaxWaitSeconds}s. Forcing termination and continuing. Details: $($_.Exception.Message)"
                try { Stop-Process -Id $pSmooth.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        catch {
            Write-Log "[WARN] Smooth shutdown actor orchestration failed: $($_.Exception.Message)"
        }

        # ==========================================================================
        # 5.2 Scheduled task trigger (user context) – bounded
        # ==========================================================================
        try {
            $pTask = Start-Process -FilePath "schtasks.exe" `
                -ArgumentList @("/run", "/tn", $TaskName) `
                -NoNewWindow -PassThru

            try {
                $null = Wait-Process -Id $pTask.Id -Timeout $StopActionMaxWaitSeconds -ErrorAction SilentlyContinue
                $taskExited = $true
            }
            catch {
                $taskExited = $false
            }

            if ($taskExited) {
                $taskExitCode = $pTask.ExitCode
                Write-Log "schtasks exited quickly. ExitCode=$taskExitCode"

                if ($taskExitCode -ne 0) {
                    Write-Log "[WARN] schtasks returned non-zero. Verify the task exists and can run under a logged-on user context."
                } else {
                    Write-Log "Scheduled task triggered successfully."
                }
            }
            else {
                Write-Log "[WARN] schtasks did not exit within ${StopActionMaxWaitSeconds}s (shutdown/RPC likely in teardown). Killing helper and continuing."
                try { Stop-Process -Id $pTask.Id -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        catch {
            Write-Log "[WARN] Failed to invoke scheduled task (best-effort). Details: $($_.Exception.Message)"
        }

        # ==========================================================================
        # 5.3 Service-context VMware authority fallback (v1.15)
        # ==========================================================================
        if (-not $taskExited -or ($taskExited -and $taskExitCode -ne 0)) {

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
                        $null = Wait-Process -Id $vp.Id -Timeout 15 -ErrorAction SilentlyContinue
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
                Write-Log "[WARN] Service-context vmrun fallback failed (best-effort). Details: $($_.Exception.Message)"
            }
        }

        Invoke-AfterVmShutdownAttempt -Attempted $true
    }
    else {
        Write-Log "Atlas flag is NOT present -> Atlas VM not considered running. No action required."
        Invoke-AfterVmShutdownAttempt -Attempted $false
    }
}
catch {
    Write-Log "[WARN] Unexpected exception in STOP handler (contained). Details: $($_.Exception.Message)"
}
finally {
    $stopEnd = Get-Date
    $durSec = ($stopEnd - $stopStart).TotalSeconds
    Write-Log ("STOP handler finished at {0} (duration seconds: {1:n2})" -f $stopEnd, $durSec)
    Write-Log "VMGuard Guard service exiting cleanly."

    # Absolute last-resort failsafe: signal STOP again (best-effort).
    try {
        & $PsExe -NoProfile -ExecutionPolicy Bypass -File $StopSignalScript *> $null
    }
    catch {
        # Never block or fail STOP on failsafe errors.
    }

    Invoke-OnGuardExit

    # ==============================================================================
    # 5.6 Termination Hardening (Eliminate Procrun StopTimeout Hangs)
    # ==============================================================================
    try {
        $subs = @(Get-EventSubscriber -ErrorAction SilentlyContinue)
        if ($subs.Count -gt 0) {
            Write-Log ("Termination hardening: Unregistering {0} event subscriber(s)." -f $subs.Count)
            foreach ($s in $subs) {
                try { Unregister-Event -SubscriptionId $s.SubscriptionId -Force -ErrorAction SilentlyContinue } catch {}
            }
        } else {
            Write-Log "Termination hardening: No event subscribers found."
        }

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

        if ($null -ne $stopEvent) {
            try { $stopEvent.Dispose() } catch {}
            $stopEvent = $null
            Write-Log "Termination hardening: Stop event handle disposed."
        }

        if ($null -ne $aliasEvents) {
            foreach ($e in $aliasEvents) {
                try { $e.Dispose() } catch {}
            }
            Write-Log "Termination hardening: Stop event alias handles disposed."
        }

        try { [System.GC]::Collect() } catch {}
        try { [System.GC]::WaitForPendingFinalizers() } catch {}

        Write-Log "Termination hardening: Forcing process exit with code 0."
    }
    catch {
        # Never block or fail STOP due to cleanup logic.
    }

    [System.Environment]::Exit(0)
}

# ==============================================================================
# END OF FILE
# ==============================================================================
