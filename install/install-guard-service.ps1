<#
================================================================================
 VMGuard – Guard Service – INSTALL – v1.5
================================================================================
 Script Name : install-guard-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-17
 Version     : 1.5

 PURPOSE
   Config-driven installer for the VMGuard Guard service.

   Evolves v1.4 CMD-based installer into a portable, centrally-configured
   model while preserving all behavioral guarantees.

 RESPONSIBILITIES
   1) Load VMGuard bootstrap + central configuration
   2) Validate required binaries and scripts
   3) Enforce VMGuard user shutdown scheduled task
   4) Enforce preshutdown sentinel wiring and dependency ordering
   5) Install or update Guard service idempotently
   6) Enforce hardened STOP contract
   7) Enforce LocalSystem execution
   8) Enforce PID tracking
   9) Start service
   10) Fail loudly on unsafe configurations

 NON-RESPONSIBILITIES
   - Does NOT define constants
   - Does NOT embed paths
   - Does NOT replace sentinel installer
   - Does NOT own runtime logic

 LIFECYCLE CONTEXT
   - Invoked exclusively by install-guard-service.cmd
================================================================================
#>

# ============================================================
# 1. Bootstrap
# ============================================================

. "$PSScriptRoot\..\common\vmguard-bootstrap.ps1"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Information","Warning","Error")][string]$Level = "Information"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"
}

Write-Log "==========================================="
Write-Log "VMGuard Guard Service INSTALL v1.5"
Write-Log "Root   : $VMGuardRoot"
Write-Log "Config : $VMGuardConfigPath"
Write-Log "==========================================="

# ============================================================
# 2. Resolve Config Domains
# ============================================================

$ServiceName  = $VMGServices.guard.name
$DisplayName  = $VMGServices.guard.displayName
$SentinelSvc  = $VMGServices.sentinel.name

$GuardPs1     = Resolve-VMGPath $VMGServices.guard.script
$StopHelper  = Resolve-VMGPath $VMGServices.guard.stopScript
$UserShutdownPs1 = Resolve-VMGPath $VMG.tasks.userShutdown.script

$LogDir      = Resolve-VMGPath $VMGPaths.logs
$RunDir      = Resolve-VMGPath $VMGPaths.run
$Procrun     = Resolve-VMGPath "exe\prunsrv.exe"

$PidFile     = Join-Path $RunDir "VMGuard-Guard.pid"
$PowerShell  = (Get-Command powershell.exe).Source

# ============================================================
# 3. Hard Validation
# ============================================================

$required = @($Procrun,$GuardPs1,$StopHelper,$UserShutdownPs1)

foreach ($item in $required) {
    if (-not (Test-Path $item)) {
        Write-Log "Required artifact missing: $item" "Error"
        exit 4001
    }
}

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Path $RunDir | Out-Null }

# ============================================================
# 4. Scheduled Task Enforcement
# ============================================================

Write-Log "==========================================="
Write-Log "VMGuard Scheduled Task Enforcement"
Write-Log "==========================================="

$TaskName = "$($VMG.tasks.userShutdown.folder)\$($VMG.tasks.userShutdown.name)"

schtasks /query /tn "$TaskName" >$null 2>&1

if ($LASTEXITCODE -ne 0) {

    Write-Log "Scheduled task not found. Creating..."

    schtasks /create `
      /tn "$TaskName" `
      /sc ONCE /st 00:00 /f `
      /tr "`"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$UserShutdownPs1`"" `
      /rl HIGHEST /it

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to create scheduled task: $TaskName" "Error"
        exit 4002
    }
}

schtasks /query /tn "$TaskName" >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "Scheduled task validation failed." "Error"
    exit 4003
}

Write-Log "Scheduled task installed and validated."

# ============================================================
# 5. Sentinel Wiring (v1.4 preserved)
# ============================================================

Write-Log "==========================================="
Write-Log "VMGuard Preshutdown Sentinel Wiring"
Write-Log "==========================================="

Set-Content query "$SentinelSvc" >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "Required preshutdown service not found: $SentinelSvc" "Error"
    exit 4004
}

Set-Content query "$SentinelSvc" | find "RUNNING" >$null 2>&1
if ($LASTEXITCODE -ne 0) { Set-Content start "$SentinelSvc" >$null 2>&1 }

Set-Content config "$ServiceName" depend= "$SentinelSvc" >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to set service dependency." "Error"
    exit 4005
}

Write-Log "Sentinel dependency enforced."

# ============================================================
# 6. Install / Update Guard Service
# ============================================================

Write-Log "==========================================="
Write-Log "Installing / Updating $ServiceName"
Write-Log "==========================================="

& "$Procrun" //IS//$ServiceName `
 --DisplayName="$DisplayName" `
 --Startup=auto `
 --StartMode=exe `
 --StartImage="$PowerShell" `
 --StartParams="-NoProfile -ExecutionPolicy Bypass -File `"$GuardPs1`"" `
 --StartPath="$VMGuardRoot" `
 --StopMode=exe `
 --StopImage="$PowerShell" `
 --StopParams="-NoProfile -ExecutionPolicy Bypass -File `"$StopHelper`"" `
 --StopTimeout=120 `
 --PidFile="$PidFile" `
 --ServiceUser=LocalSystem `
 --LogPath="$LogDir" `
 --LogPrefix=VMGuard-Guard-procrun `
 --LogLevel=Info `
 --StdOutput="$LogDir\VMGuard-Guard-stdout.log" `
 --StdError="$LogDir\VMGuard-Guard-stderr.log"

if ($LASTEXITCODE -ne 0) {
    Write-Log "Service installation failed." "Error"
    exit 4010
}

# ============================================================
# 7. Guardrail — LocalSystem enforcement
# ============================================================

Set-Content qc $ServiceName | find "LocalSystem" >$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Service is NOT LocalSystem. Rolling back." "Error"
    & "$Procrun" //DS//$ServiceName >$null 2>&1
    exit 4011
}

Write-Log "Service account validated: LocalSystem"

# ============================================================
# 8. Start Service
# ============================================================

Set-Content start $ServiceName >$null 2>&1

Write-Log "==========================================="
Write-Log "INSTALL COMPLETE"
Write-Log "==========================================="

exit 0
