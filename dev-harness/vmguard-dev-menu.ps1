<#
================================================================================
 VMGuard – Developer Control Panel – v1.10
================================================================================
 Script Name : vmguard-dev-menu.ps1
 Author      : javaboy-vk
 Date        : 2026-01-14
 Version     : 1.10

 PURPOSE
   Central control panel for VMGuard dev harness and architecture tooling.

 v1.10 CHANGE
   - Normalized Host Shutdown Interceptor under \Protepo namespace
   - Added full host interceptor task dump option
   - Added VMGuard scheduled-task sweep option

 v1.9 CHANGE
   - Added Host Shutdown Interceptor control plane
   - Added scheduled-task management for host interceptor
   - Architecture verification now classifies Host Interceptor plane
   - Control-plane dump now includes host interceptor
   - Added manual trigger and enable/disable support

 v1.8 CHANGE
   - Removed "Press Enter to continue..." pausing behavior from options 8, 9, 11
     (harness returns to menu immediately after completing the action).
   - Upgraded architecture verification from fault detection to topology classification:
       * ARCH-FAULT only for missing CORE components
       * User shutdown task is OPTIONAL (WARN if missing)
       * Emits architecture MODE and plane classification (Service/STOP/User).

 v1.7 CHANGE
   - Added VMGuard Architecture Tools section
   - Added scheduled-task repair capability
   - Added architecture verification
   - Added control-plane state dump

 v1.6 CHANGE
   - Renamed Args parameter to PositionalArgs.
   - Avoids collision with built-in PowerShell automatic variable $Args.
   - Preserves named-parameter splatting and positional invocation model.
================================================================================
#>

param(
    [string]$BaseDir    = 'P:\Scripts\VMGuard',
    [string]$HarnessDir = 'P:\Scripts\VMGuard\dev-harness',
    [string]$VmName     = 'AtlasW19'
)

# ==============================================================================
# CORE HARNESS INVOKER
# ==============================================================================

function Invoke-VMGuardScript {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$NamedArgs = @{},
        [object[]]$PositionalArgs = @()
    )

    $p = Join-Path $HarnessDir $Name

    if (Test-Path $p) {
        & $p @NamedArgs @PositionalArgs
    } else {
        Write-Host "Missing: $p"
    }
}

# ==============================================================================
# HOST SHUTDOWN INTERCEPTOR TOOLS
# ==============================================================================

$HostInterceptorName = '\Protepo\VMGuard-HostShutdown-Interceptor'
$HostInterceptorInstaller = 'P:\Scripts\VMGuard\install\install-vmguard-host-shutdown-interceptor.cmd'

function Invoke-VMGuardHostInterceptorStatus {
    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Host Shutdown Interceptor Status'
    Write-Host '==========================================='

    schtasks /query /tn $HostInterceptorName /v /fo list 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host '[WARN] Host shutdown interceptor not installed.'
    }
}

function Invoke-VMGuardHostInterceptorRun {
    Write-Host '[INFO] Manually triggering host shutdown interceptor...'
    schtasks /run /tn $HostInterceptorName
}

function Invoke-VMGuardHostInterceptorEnable {
    schtasks /change /tn $HostInterceptorName /enable
}

function Invoke-VMGuardHostInterceptorDisable {
    schtasks /change /tn $HostInterceptorName /disable
}

function Invoke-VMGuardHostInterceptorReinstall {

    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Host Shutdown Interceptor Repair'
    Write-Host '==========================================='

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host '[FATAL] Administrator privileges are required.'
        return
    }

    if (-not (Test-Path $HostInterceptorInstaller)) {
        Write-Host '[FATAL] Installer not found:'
        Write-Host "        $HostInterceptorInstaller"
        return
    }

    cmd.exe /c $HostInterceptorInstaller
}

function Invoke-VMGuardHostInterceptorRawDump {
    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Host Interceptor – Full Task Dump'
    Write-Host '==========================================='
    schtasks /Query /TN $HostInterceptorName /V /FO LIST
}

function Invoke-VMGuardScheduledTaskSweep {
    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Scheduled Task Sweep'
    Write-Host '==========================================='
    schtasks /Query | findstr /I 'VMGuard'
}

# ==============================================================================
# ARCHITECTURE TOOLS
# ==============================================================================

function Invoke-VMGuardTaskRepair {

    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Scheduled Task Repair'
    Write-Host '==========================================='

    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host '[FATAL] Administrator privileges are required to install system tasks.'
        Write-Host '        Restart this harness with: Run as Administrator'
        return
    }

    $taskName = '\Protepo\VMGuard-Guard-User'
    $psExe    = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $script   = Join-Path $BaseDir 'guard\vm-smooth-shutdown.ps1'

    if (-not (Test-Path $script)) {
        Write-Host '[FATAL] vm-smooth-shutdown.ps1 not found:'
        Write-Host "        $script"
        return
    }

    schtasks /delete /tn $taskName /f > $null 2>&1

    schtasks /create `
        /tn '\Protepo\__folder_init__' `
        /sc ONLOGON /ru SYSTEM /rl HIGHEST /f `
        /tr 'cmd.exe /c exit' > $null 2>&1

    schtasks /delete /tn '\Protepo\__folder_init__' /f > $null 2>&1

    schtasks /create `
      /tn $taskName `
      /sc ONLOGON `
      /ru SYSTEM `
      /rl HIGHEST `
      /f `
      /tr "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""

    if ($LASTEXITCODE -eq 0) {
        Write-Host '[PASS] VMGuard user-plane task installed.'
        Write-Host '       Trigger : ONLOGON'
        Write-Host '       Principal: SYSTEM (HIGHEST)'
    }
    else {
        Write-Host '[FAIL] Scheduled task creation failed.'
    }
}

function Invoke-VMGuardArchitectureCheck {

    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Architecture Verification'
    Write-Host '==========================================='

    $fatalIssues = 0
    $warnings    = 0

    $serviceName = 'VMGuard-Guard'
    $userTask    = '\Protepo\VMGuard-Guard-User'
    $hostTask    = '\Protepo\VMGuard-HostShutdown-Interceptor'

    $stopSignal  = Join-Path $BaseDir 'guard\vmguard-guard-stop-event-signal.ps1'
    $guardPs1    = Join-Path $BaseDir 'guard\vmguard-service.ps1'
    $smoothPs1   = Join-Path $BaseDir 'guard\vm-smooth-shutdown.ps1'

    sc.exe query $serviceName > $null 2>&1
    $servicePresent = ($LASTEXITCODE -eq 0)

    if ($servicePresent) { Write-Host '[PASS] Guard service registered. (CORE)' }
    else { Write-Host '[FAIL] Guard service missing. (CORE)'; $fatalIssues++ }

    schtasks /query /tn $userTask > $null 2>&1
    $userTaskPresent = ($LASTEXITCODE -eq 0)

    if ($userTaskPresent) { Write-Host '[PASS] User shutdown task present. (OPTIONAL)' }
    else { Write-Host '[WARN] User shutdown task not installed. (OPTIONAL)'; $warnings++ }

    schtasks /query /tn $hostTask > $null 2>&1
    $hostTaskPresent = ($LASTEXITCODE -eq 0)

    if ($hostTaskPresent) { Write-Host '[PASS] Host interceptor present. (OPTIONAL)' }
    else { Write-Host '[WARN] Host interceptor not installed. (OPTIONAL)'; $warnings++ }

    $stopPresent = (Test-Path $stopSignal)
    if ($stopPresent) { Write-Host '[PASS] STOP signaler present. (CORE)' }
    else { Write-Host '[FAIL] STOP signaler missing. (CORE)'; $fatalIssues++ }

    $guardScriptPresent  = (Test-Path $guardPs1)
    $smoothScriptPresent = (Test-Path $smoothPs1)

    if ($guardScriptPresent) { Write-Host '[PASS] Guard service script present. (CORE)' }
    else { Write-Host '[FAIL] Guard service script missing. (CORE)'; $fatalIssues++ }

    if ($smoothScriptPresent) { Write-Host '[PASS] Smooth shutdown script present. (CORE)' }
    else { Write-Host '[FAIL] Smooth shutdown script missing. (CORE)'; $fatalIssues++ }

    Write-Host ''

    if ($fatalIssues -gt 0) {
        $mode = 'ARCH-FAULT'
    }
    else {
        if ($userTaskPresent -or $hostTaskPresent) { $mode = 'ARCH-FULL' }
        else { $mode = 'ARCH-SERVICE-ONLY' }
    }

    $servicePlane = if ($servicePresent) { 'Service' } else { 'Service(MISSING)' }
    $stopPlane    = if ($stopPresent)    { 'STOP' }    else { 'STOP(MISSING)' }
    $userPlane    = if ($userTaskPresent){ 'User' }    else { 'User(disabled)' }
    $hostPlane    = if ($hostTaskPresent){ 'Host' }    else { 'Host(disabled)' }

    Write-Host "VMGuard architecture mode : $mode"
    Write-Host "Active planes             : $servicePlane, $stopPlane, $userPlane, $hostPlane"

    if ($fatalIssues -gt 0 -or $warnings -gt 0) {
        Write-Host "Issues                    : FATAL=$fatalIssues, WARN=$warnings"
    }
    else {
        Write-Host 'Issues                    : none'
    }
}

function Invoke-VMGuardControlPlaneDump {

    Write-Host ''
    Write-Host '==========================================='
    Write-Host ' VMGuard Control Plane State Dump'
    Write-Host '==========================================='

    Write-Host '--- Services ---'
    sc.exe query VMGuard-Guard

    Write-Host ''
    Write-Host '--- Scheduled Tasks ---'
    schtasks /query /tn '\Protepo\VMGuard-Guard-User' /v /fo list 2>$null
    schtasks /query /tn '\Protepo\VMGuard-HostShutdown-Interceptor' /v /fo list 2>$null

    Write-Host ''
    Write-Host '--- Key Artifacts ---'
    Get-Item "$BaseDir\guard\vmguard-service.ps1" -ErrorAction SilentlyContinue
    Get-Item "$BaseDir\guard\vm-smooth-shutdown.ps1" -ErrorAction SilentlyContinue
    Get-Item "$BaseDir\guard\vmguard-guard-stop-event-signal.ps1" -ErrorAction SilentlyContinue
    Get-Item "$BaseDir\guard\vmguard-host-shutdown-interceptor.ps1" -ErrorAction SilentlyContinue
}

# ==============================================================================
# MAIN MENU LOOP
# ==============================================================================

while ($true)
{
    Write-Host ''
    Write-Host 'VMGuard Developer Harness v1.10'
    Write-Host '--------------------------------'
    Write-Host '1  - Health Check'
    Write-Host '2  - Reset State (target VM)'
    Write-Host '3  - Reset State (ALL flags)'
    Write-Host '4  - Run Guard Interactive'
    Write-Host '5  - Trigger STOP event'
    Write-Host '6  - Tail Guard Logs'
    Write-Host '7  - Tail Harness Logs'
    Write-Host '8  - Install / Repair user shutdown task'
    Write-Host '9  - Verify VMGuard architecture'
    Write-Host '10 - Simulate VM running (on/off/status)'
    Write-Host '11 - Dump VMGuard control-plane state'
    Write-Host '12 - Host interceptor status'
    Write-Host '13 - Host interceptor run now'
    Write-Host '14 - Host interceptor enable'
    Write-Host '15 - Host interceptor disable'
    Write-Host '16 - Host interceptor reinstall'
    Write-Host '17 - Host interceptor full task dump'
    Write-Host '18 - List all VMGuard scheduled tasks'
    Write-Host 'Q  - Quit'

    $c = (Read-Host 'Select').Trim().ToUpperInvariant()

    switch ($c) {
        '1'  { Invoke-VMGuardScript -Name 'vmguard-healthcheck.ps1' }
        '2'  { Invoke-VMGuardScript -Name 'vmguard-reset-state.ps1' -PositionalArgs @($VmName) }
        '3'  { Invoke-VMGuardScript -Name 'vmguard-reset-state.ps1' -NamedArgs @{ ResetAllFlags = $true } }
        '4'  { Invoke-VMGuardScript -Name 'vmguard-run-interactive.ps1' }
        '5'  { Invoke-VMGuardScript -Name 'vmguard-manual-stop.ps1' }
        '6'  { Invoke-VMGuardScript -Name 'vmguard-tail-logs.ps1' -NamedArgs @{ Which = 'guard' } }
        '7'  { Invoke-VMGuardScript -Name 'vmguard-tail-logs.ps1' -NamedArgs @{ Which = 'harness' } }
        '8'  { Invoke-VMGuardTaskRepair }
        '9'  { Invoke-VMGuardArchitectureCheck }

        '10' {
            $mode = (Read-Host 'Enter mode (on/off/status)').Trim().ToLowerInvariant()
            Invoke-VMGuardScript -Name 'vmguard-simulate-vm-running.ps1' -PositionalArgs @($mode)
        }

        '11' { Invoke-VMGuardControlPlaneDump }

        '12' { Invoke-VMGuardHostInterceptorStatus }
        '13' { Invoke-VMGuardHostInterceptorRun }
        '14' { Invoke-VMGuardHostInterceptorEnable }
        '15' { Invoke-VMGuardHostInterceptorDisable }
        '16' { Invoke-VMGuardHostInterceptorReinstall }
        '17' { Invoke-VMGuardHostInterceptorRawDump }
        '18' { Invoke-VMGuardScheduledTaskSweep }

        'Q'  { return }
    }
}
