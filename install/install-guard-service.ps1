<#
================================================================================
 VMGuard – Guard Service – INSTALL – v1.19
================================================================================
 Script Name : install-guard-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-19
 Version     : 1.19

 PURPOSE
   Config-driven installer for the VMGuard Guard service.

 KEY FIX (v1.15)
   Do NOT re-log external log streams (procrun/stdout/stderr) into vmguard.log.
   - VMGuard file logs must contain exactly one VMGuard level token per line (INFO/WARN/ERROR).
   - External logs may include their own [info]/[error] tokens and must NOT be wrapped into vmguard.log.
   - Diagnostic excerpts remain CONSOLE-ONLY; vmguard.log records only pointers (paths) and VMGuard events.

 KEY FIX (v1.16)
   External stream lines MUST be emitted RAW on console (no VMGuard prefix).

 KEY FIX (v1.18)
   Procrun StartParams/StopParams must be passed as repeated --StartParams/--StopParams entries.
   - Avoids broken "++" tokenization causing PowerShell to receive a single token like:
     -NoProfile++-ExecutionPolicy++Bypass++-File++P:\...

 KEY FIX (v1.19)
   Normalize Apache procrun timestamp bracket format on CONSOLE output:
   - [2026-01-19 14:04:37] [info] ...  ->  2026-01-19 14:04:37 [info] ...
   - Only affects console rendering of external streams; does NOT alter external log files on disk.
   - Procrun install/update output is captured and emitted via the external-stream emitter to apply normalization.
================================================================================
#>

# ============================================================
# 1. Bootstrap
# ============================================================

. "$PSScriptRoot\..\common\vmguard-bootstrap.ps1"

# ============================================================
# 1.1 Canonical Logging Primitive
# ============================================================

$LoggingModulePath = Join-Path $PSScriptRoot "..\common\logging.ps1"

if (-not (Test-Path $LoggingModulePath)) {
    Write-Host "FATAL: Canonical logging module not found at: $LoggingModulePath" -ForegroundColor Red
    exit 4099
}

. $LoggingModulePath

# Resolve separator from config (fallback preserved)
$Separator = "==========================================="
if ($VMG.logging -and $VMG.logging.separator) { $Separator = $VMG.logging.separator }

# ============================================================
# 2. Resolve Config Domains
# ============================================================

$ServiceName   = $VMGServices.guard.name
$DisplayName   = $VMGServices.guard.displayName
$SentinelSvc   = $VMGServices.sentinel.name

$ServiceDescription = $VMGServices.guard.description
if ([string]::IsNullOrWhiteSpace($ServiceDescription)) { $ServiceDescription = $DisplayName }

$GuardPs1        = Resolve-VMGPath $VMGServices.guard.script
$StopHelper      = Resolve-VMGPath $VMGServices.guard.stopScript
$UserShutdownPs1 = Resolve-VMGPath $VMG.tasks.userShutdown.script

$LogDir      = Resolve-VMGPath $VMGPaths.logs
$RunDir      = Resolve-VMGPath $VMGPaths.run
$Procrun     = Resolve-VMGPath "exe\prunsrv.exe"

$PidFile     = Join-Path $RunDir "VMGuard-Guard.pid"
$PowerShell  = (Get-Command powershell.exe).Source

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }

$Global:VMGuardBaseDir = $VMGuardRoot
$Global:VMGuardLogFile = Join-Path $LogDir "vmguard.log"
$Global:VMGuardSource  = "VMGuard"

# ============================================================
# 2.1 Installer Logging
# ============================================================

function Write-InstallLog {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO",

        [switch]$ConsoleOnly
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"

    if (-not $ConsoleOnly) {
        try { Write-Log -Level $Level -Message $Message } catch {}
    }
}

function Write-ExternalStreamLine {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrEmpty($Line)) {
        Write-Host ""
        return
    }

    # v1.19: Normalize ONLY the leading timestamp brackets used by procrun:
    # [2026-01-19 14:04:37] [info] ...  ->  2026-01-19 14:04:37 [info] ...
    $normalized = $Line -replace '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]\s+', '$1 '

    # Raw console output: no VMGuard prefix, no extra tokens.
    Write-Host $normalized
}

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Guard Service INSTALL v1.19"
Write-InstallLog -Message "Root   : $VMGuardRoot"
Write-InstallLog -Message "Config : $VMGuardConfigPath"
Write-InstallLog -Message $Separator

# ============================================================
# 3. Hard Validation
# ============================================================

$required = @($Procrun,$GuardPs1,$StopHelper,$UserShutdownPs1)
foreach ($item in $required) {
    if (-not (Test-Path $item)) {
        Write-InstallLog -Level "ERROR" -Message "Required artifact missing: $item"
        exit 4001
    }
}

# ============================================================
# 4. Scheduled Task Enforcement
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Scheduled Task Enforcement"
Write-InstallLog -Message $Separator

$TaskName = "$($VMG.tasks.userShutdown.folder)\$($VMG.tasks.userShutdown.name)"
schtasks /query /tn "$TaskName" >$null 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-InstallLog -Message "Scheduled task not found. Creating..."

    schtasks /create `
      /tn "$TaskName" `
      /sc ONCE /st 00:00 /f `
      /tr "`"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$UserShutdownPs1`"" `
      /rl HIGHEST /it

    if ($LASTEXITCODE -ne 0) {
        Write-InstallLog -Level "ERROR" -Message "Failed to create scheduled task: $TaskName"
        exit 4002
    }
}

schtasks /query /tn "$TaskName" >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-InstallLog -Level "ERROR" -Message "Scheduled task validation failed."
    exit 4003
}

Write-InstallLog -Message "Scheduled task installed and validated."

# ============================================================
# 5. Sentinel Precheck (presence + running state)
#    + Enforce Sentinel AUTO_START
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Preshutdown Sentinel Precheck"
Write-InstallLog -Message $Separator

$sentinel = Get-Service -Name $SentinelSvc -ErrorAction SilentlyContinue
if (-not $sentinel) {
    Write-InstallLog -Level "ERROR" -Message "Required preshutdown service not found: $SentinelSvc"
    exit 4004
}

try {
    $sentinelCim = Get-CimInstance Win32_Service -Filter "Name='$SentinelSvc'" -ErrorAction Stop
    if ($sentinelCim.StartMode -ne "Auto") {
        Write-InstallLog -Level "WARN" -Message "Sentinel StartMode is '$($sentinelCim.StartMode)'. Enforcing AUTO_START."
        $scOut = & "$env:SystemRoot\System32\sc.exe" config $SentinelSvc "start=" "auto" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-InstallLog -Level "ERROR" -Message "Failed to enforce Sentinel AUTO_START. $scOut"
            exit 4004
        }
    }
} catch {
    Write-InstallLog -Level "WARN" -Message "Unable to validate/enforce Sentinel StartMode via CIM. Proceeding. $_"
}

if ($sentinel.Status -ne "Running") {
    try {
        Start-Service -Name $SentinelSvc -ErrorAction Stop
        $sentinel = Get-Service -Name $SentinelSvc -ErrorAction Stop
        if ($sentinel.Status -ne "Running") { throw "Sentinel did not reach Running. CurrentStatus=$($sentinel.Status)" }
        Write-InstallLog -Message "Sentinel service started."
    } catch {
        Write-InstallLog -Level "ERROR" -Message "Failed to start preshutdown sentinel service '$SentinelSvc'. $_"
        exit 4004
    }
} else {
    Write-InstallLog -Message "Sentinel service already running."
}

# ============================================================
# 6. Install / Update Guard Service (idempotent)
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "Installing / Updating $ServiceName"
Write-InstallLog -Message $Separator

$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$procrunVerb = "IS"
if ($existingSvc) { $procrunVerb = "US" }

if ($existingSvc) {
    Write-InstallLog -Message "Service exists. Performing UPDATE via procrun (//US//)."
    try {
        if ($existingSvc.Status -ne "Stopped") {
            Write-InstallLog -Message "Requesting existing service stop prior to update..."
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Start-Sleep -Seconds 1
        }
    } catch {
        Write-InstallLog -Level "WARN" -Message "Unable to stop existing service prior to update. Proceeding. $_"
    }
} else {
    Write-InstallLog -Message "Service not present. Performing INSTALL via procrun (//IS//)."
}

# v1.19: Capture procrun output so we can normalize bracketed timestamps on console
$procrunOut = & "$Procrun" //"${procrunVerb}"//$ServiceName `
 --DisplayName="$DisplayName" `
 --Description="$ServiceDescription" `
 --Startup=auto `
 --StartMode=exe `
 --StartImage="$PowerShell" `
 --StartParams=-NoProfile `
 --StartParams=-ExecutionPolicy `
 --StartParams=Bypass `
 --StartParams=-File `
 --StartParams="$GuardPs1" `
 --StartPath="$VMGuardRoot" `
 --StopMode=exe `
 --StopImage="$PowerShell" `
 --StopParams=-NoProfile `
 --StopParams=-ExecutionPolicy `
 --StopParams=Bypass `
 --StopParams=-File `
 --StopParams="$StopHelper" `
 --StopTimeout=120 `
 --PidFile="$PidFile" `
 --ServiceUser=LocalSystem `
 --LogPath="$LogDir" `
 --LogPrefix=VMGuard-Guard-procrun `
 --LogLevel=Info `
 --StdOutput="$LogDir\VMGuard-Guard-stdout.log" `
 --StdError="$LogDir\VMGuard-Guard-stderr.log" 2>&1

$procrunExit = $LASTEXITCODE

# Emit procrun output as external stream (RAW, normalized timestamp brackets)
$procrunOut | ForEach-Object { Write-ExternalStreamLine -Line $_ }

if ($procrunExit -ne 0) {
    Write-InstallLog -Level "ERROR" -Message "Service install/update failed via procrun (//${procrunVerb}//). ExitCode=$procrunExit"
    exit 4010
}

# ============================================================
# 6.1 Sentinel Dependency Enforcement
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Preshutdown Sentinel Dependency Wiring"
Write-InstallLog -Message $Separator

try {
    $scOut = & "$env:SystemRoot\System32\sc.exe" config $ServiceName "depend=" "$SentinelSvc" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed (ExitCode=$LASTEXITCODE): $scOut" }

    $qc = & "$env:SystemRoot\System32\sc.exe" qc $ServiceName 2>&1
    Write-InstallLog -Message "Sentinel dependency enforced."
    Write-InstallLog -Message "--- sc.exe qc $ServiceName (dependency verification) ---"
    $qc | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Message $_ } }
}
catch {
    Write-InstallLog -Level "ERROR" -Message "Failed to set service dependency. $_"
    & "$Procrun" //DS//$ServiceName >$null 2>&1
    exit 4005
}

# ============================================================
# 7. Guardrail — LocalSystem enforcement
# ============================================================

try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
} catch {
    Write-InstallLog -Level "ERROR" -Message "Unable to query service '$ServiceName' for StartName. $_"
    exit 4011
}

if ($svc.StartName -ne "LocalSystem") {
    Write-InstallLog -Level "ERROR" -Message "Service is NOT LocalSystem (StartName='$($svc.StartName)'). Rolling back."
    & "$Procrun" //DS//$ServiceName >$null 2>&1
    exit 4011
}

Write-InstallLog -Message "Service account validated: LocalSystem"

# ============================================================
# 8. Start Service (with diagnostics on failure)
# ============================================================

function Dump-GuardStartDiagnostics {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$SentinelSvc,
        [Parameter(Mandatory=$true)][string]$LogDir,
        [Parameter(Mandatory=$true)][string]$Separator
    )

    Write-InstallLog -Level "ERROR" -Message $Separator
    Write-InstallLog -Level "ERROR" -Message "VMGuard Guard START FAILURE DIAGNOSTICS"
    Write-InstallLog -Level "ERROR" -Message $Separator

    try {
        Write-InstallLog -Level "ERROR" -Message "--- sc.exe qc (Guard) ---"
        (& "$env:SystemRoot\System32\sc.exe" qc $ServiceName 2>&1) | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Level "ERROR" -Message $_ }
        }
    } catch {}

    try {
        Write-InstallLog -Level "ERROR" -Message "--- sc.exe qc (Sentinel) ---"
        (& "$env:SystemRoot\System32\sc.exe" qc $SentinelSvc 2>&1) | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Level "ERROR" -Message $_ }
        }
    } catch {}

    try {
        $s = Get-Service -Name $SentinelSvc -ErrorAction Stop
        Write-InstallLog -Level "ERROR" -Message "Sentinel Status : $($s.Status)"
        Write-InstallLog -Level "ERROR" -Message "Sentinel Name   : $($s.Name)"
        Write-InstallLog -Level "ERROR" -Message "Sentinel Display: $($s.DisplayName)"
    } catch {}

    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
        Write-InstallLog -Level "ERROR" -Message "ServiceName              : $($svc.Name)"
        Write-InstallLog -Level "ERROR" -Message "State                    : $($svc.State)"
        Write-InstallLog -Level "ERROR" -Message "StartMode                : $($svc.StartMode)"
        Write-InstallLog -Level "ERROR" -Message "StartName                : $($svc.StartName)"
        Write-InstallLog -Level "ERROR" -Message "PathName                 : $($svc.PathName)"
        Write-InstallLog -Level "ERROR" -Message "ExitCode                 : $($svc.ExitCode)"
        Write-InstallLog -Level "ERROR" -Message "ServiceSpecificExitCode  : $($svc.ServiceSpecificExitCode)"
    } catch {}

    try {
        $stdOut = Join-Path $LogDir "VMGuard-Guard-stdout.log"
        $stdErr = Join-Path $LogDir "VMGuard-Guard-stderr.log"

        Write-InstallLog -Level "ERROR" -Message "LogDir  : $LogDir"
        Write-InstallLog -Level "ERROR" -Message "STDOUT  : $stdOut"
        Write-InstallLog -Level "ERROR" -Message "STDERR  : $stdErr"
        Write-InstallLog -Level "ERROR" -Message "PROCRUN : (see VMGuard-Guard-procrun*.log under LogDir)"

        if (Test-Path $stdOut) {
            Write-InstallLog -Level "ERROR" -Message "--- STDOUT (last 200 lines, RAW console) ---" -ConsoleOnly
            Get-Content $stdOut -Tail 200 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
            }
        }

        if (Test-Path $stdErr) {
            Write-InstallLog -Level "ERROR" -Message "--- STDERR (last 200 lines, RAW console) ---" -ConsoleOnly
            Get-Content $stdErr -Tail 200 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
            }
        }

        $procrunLogs = Get-ChildItem -Path $LogDir -Filter "VMGuard-Guard-procrun*.log" -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 3

        if ($procrunLogs) {
            $names = ($procrunLogs | ForEach-Object { $_.FullName }) -join "; "
            Write-InstallLog -Level "ERROR" -Message "PROCRUN (latest 3): $names"

            foreach ($f in $procrunLogs) {
                Write-InstallLog -Level "ERROR" -Message "--- PROCRUN LOG (RAW console): $($f.FullName) (last 200 lines) ---" -ConsoleOnly
                Get-Content $f.FullName -Tail 200 | ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
                }
            }
        }
    } catch {}

    try {
        Write-InstallLog -Level "ERROR" -Message "--- Service Control Manager (System log, last 15 events) ---"
        Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager' } -MaxEvents 15 |
            ForEach-Object {
                $msg = $_.Message -replace "`r`n"," | "
                Write-InstallLog -Level "ERROR" -Message "$($_.TimeCreated) :: $msg"
            }
    } catch {}
}

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 2

    $gs = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($gs.Status -ne "Running") { throw "Service transitioned to '$($gs.Status)' shortly after start." }
}
catch {
    Write-InstallLog -Level "ERROR" -Message "Failed to start service '$ServiceName' or it did not remain Running. $_"
    Dump-GuardStartDiagnostics -ServiceName $ServiceName -SentinelSvc $SentinelSvc -LogDir $LogDir -Separator $Separator
    exit 4012
}

Write-InstallLog -Message "Service started and validated (Running): $ServiceName"

Write-InstallLog -Message $Separator
Write-InstallLog -Message "INSTALL COMPLETE"
Write-InstallLog -Message $Separator

exit 0
