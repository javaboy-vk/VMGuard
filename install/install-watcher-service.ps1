<#
================================================================================
 VMGuard – Watcher Service – INSTALL – v2.2
================================================================================
 Script Name : install-watcher-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-25
 Version     : 2.2

 PURPOSE
   Install or update the VMGuard Watcher as a LocalSystem Windows service using
   Apache Procrun (prunsrv.exe).

 PORTABILITY
   - Anchors VMGuard root relative to this installer location.
   - Uses conf\env.properties + conf\settings.json via vmguard-bootstrap.ps1.
   - No hard-coded drive letters.

 STOP CONTRACT (SACRED)
   - Watcher runs until STOP is signaled via a named kernel event.
   - Procrun STOP hook invokes watcher\vmguard-watcher-stop.cmd (or configured
     stopScript) which MUST signal the watcher stop event and exit 0.
   - This installer reads the configured StopEvent name from settings.json:
       tasks.events.watcherStop  (via bootstrap alias events.watcherStop)

 v2.2 CHANGE
   - Bootstrap script selection occurs before StartParams so service runs bootstrap

 v2.1 CHANGE
   - Prefer vm-watcher-bootstrap.ps1 when present to ensure env.properties import

 v2.0 CHANGE
   - Schema compatibility: supports tasks.events.* (current) and events.* (legacy)
     through bootstrap aliasing.
   - Eliminates dependency on broken .cmd wrapper quoting.
================================================================================
#>

$ErrorActionPreference = 'Stop'

# ==============================================================================
# Bootstrap (root + config)
# ==============================================================================
$Bootstrap = Join-Path $PSScriptRoot '..\common\vmguard-bootstrap.ps1'
$Bootstrap = (Resolve-Path $Bootstrap).Path
. $Bootstrap

# ==============================================================================
# Resolve contract from settings.json
# ==============================================================================
$SvcName      = $VMGServices.watcher.name
$DisplayName  = $VMGServices.watcher.displayName
$Description  = $VMGServices.watcher.description

if (-not $SvcName)     { $SvcName = 'VMGuard-Watcher' }
if (-not $DisplayName) { $DisplayName = 'VMGuard Watcher Service' }
if (-not $Description) { $Description = 'VMGuard Watcher Service' }

$WatcherPs1 = Resolve-VMGPath $VMGServices.watcher.script
$StopHelper = Resolve-VMGPath $VMGServices.watcher.stopScript

$LogDir     = Resolve-VMGPath $VMGPaths.logs
$Procrun    = Resolve-VMGPath 'exe\prunsrv.exe'
$PsExe      = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$StopEvent  = $VMGEvents.watcherStop
if (-not $StopEvent) { $StopEvent = 'Global\VMGuard_Watcher_Stop' }

$BootstrapPs1 = Join-Path (Split-Path $WatcherPs1 -Parent) "vm-watcher-bootstrap.ps1"
if (Test-Path $BootstrapPs1) { $WatcherPs1 = $BootstrapPs1 }

Write-Host ''
Write-Host '==========================================='
Write-Host ' VMGuard Watcher Service INSTALL v2.2'
Write-Host '==========================================='
Write-Host "Root       : $VMGuardRoot"
Write-Host "Settings   : $VMGuardConfigPath"
Write-Host "EnvProps   : $VMGuardEnvPropsPath"
Write-Host "Service    : $SvcName"
Write-Host "Script     : $WatcherPs1"
Write-Host "StopHelper : $StopHelper"
Write-Host "StopEvent  : $StopEvent"
Write-Host "Procrun    : $Procrun"
Write-Host "LogDir     : $LogDir"
Write-Host ''

# ==============================================================================
# Preconditions
# ==============================================================================
foreach ($p in @($Procrun, $WatcherPs1, $StopHelper, $PsExe)) {
    if (-not (Test-Path $p)) {
        Write-Host "[FATAL] Missing required path: $p" -ForegroundColor Red
        exit 4001
    }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# ==============================================================================
# Install / Update via Procrun
# ==============================================================================
$StartParams = "-NoProfile;-ExecutionPolicy;Bypass;-File;`"$WatcherPs1`""
$StopParams  = "/c `"$StopHelper`""

$svcExists = $false
try {
    sc.exe query $SvcName > $null 2>&1
    if ($LASTEXITCODE -eq 0) { $svcExists = $true }
} catch {
    $svcExists = $false
}

$procrunAction = if ($svcExists) { ("//US//{0}" -f $SvcName) } else { ("//IS//{0}" -f $SvcName) }

$procrunArgs = @(
    $procrunAction,
    ("--DisplayName={0}" -f $DisplayName),
    ("--Description={0}" -f $Description),
    "--Startup=auto",

    "--StartMode=exe",
    ("--StartImage={0}" -f $PsExe),
    ("--StartParams={0}" -f $StartParams),
    ("--StartPath={0}" -f $VMGuardRoot),

    "--StopMode=exe",
    ("--StopImage={0}" -f $env:ComSpec),
    ("--StopParams={0}" -f $StopParams),
    "--StopTimeout=120",

    "--ServiceUser=LocalSystem",

    ("--LogPath={0}" -f $LogDir),
    "--LogPrefix=VMGuard-Watcher-procrun",
    "--LogLevel=Info",
    ("--StdOutput={0}" -f (Join-Path $LogDir 'VMGuard-Watcher-stdout.log')),
    ("--StdError={0}"  -f (Join-Path $LogDir 'VMGuard-Watcher-stderr.log'))
)

Write-Host "[INFO] Installing / Updating $SvcName via procrun..."
& $Procrun @procrunArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] Procrun install failed. ExitCode=$LASTEXITCODE" -ForegroundColor Red
    exit 4002
}

# ==============================================================================
# Guardrail – verify LocalSystem
# ==============================================================================
$qc = (sc.exe qc $SvcName) 2>$null
$startName = $null
$qcText = $qc -join "`n"
if ($qcText -match '(?im)SERVICE_START_NAME\s+:\s+(.+)$') {
    $startName = $matches[1].Trim()
}
if (-not $startName) {
    try {
        $startName = (Get-CimInstance Win32_Service -Filter "Name='$SvcName'").StartName
    } catch {
        $startName = $null
    }
}
if (-not $startName -or $startName -notmatch '^(?i)(LocalSystem|NT AUTHORITY\\LocalSystem)$') {
    Write-Host ''
    Write-Host '[FATAL] Service account is NOT LocalSystem.' -ForegroundColor Red
    Write-Host '        This configuration is unsupported for VMGuard.' -ForegroundColor Red
    if ($startName) {
        Write-Host "        Actual account: $startName" -ForegroundColor Red
    }
    Write-Host '        Aborting and uninstalling service to prevent damage.' -ForegroundColor Red
    & $Procrun ("//DS//{0}" -f $SvcName) > $null 2>&1
    exit 4003
}
Write-Host '[PASS] Service account validated: LocalSystem'

# ==============================================================================
# Start + validate
# ==============================================================================
Write-Host '[INFO] Starting service...'
sc.exe start $SvcName > $null 2>&1

Start-Sleep -Seconds 2

sc.exe query $SvcName | findstr /I "RUNNING" > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] Service did not reach RUNNING state: $SvcName" -ForegroundColor Red
    exit 4004
}

Write-Host "[PASS] Service is RUNNING: $SvcName"
Write-Host ''
Write-Host '[SUCCESS] VMGuard Watcher installed successfully.'
exit 0


