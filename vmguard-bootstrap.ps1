<#
================================================================================
 VMGuard – Unified Bootstrap – v1.0
================================================================================
 Script Name : vmguard-bootstrap.ps1
 Author      : javaboy-vk
 Date        : 2026-01-17
 Version     : 1.0

 PURPOSE
   Provides a single canonical bootstrap for all VMGuard PowerShell artifacts.
   Loads configuration, resolves runtime paths, initializes logging context,
   and exposes a shared $VMGuard object.

 RESPONSIBILITIES
   - Locate VMGuard root
   - Load vmguard.config.json
   - Resolve and validate all runtime paths
   - Initialize common logging metadata

 NON-RESPONSIBILITIES
   - Does NOT control services
   - Does NOT signal kernel events
   - Does NOT implement business logic

 LIFECYCLE CONTEXT
   Must be dot-sourced by all VMGuard scripts and services.

================================================================================
#>

# ============================================================
# 1. Root Resolution
# ============================================================

$BootstrapRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$VMGuardRoot   = Resolve-Path $BootstrapRoot

$ConfigPath = Join-Path $VMGuardRoot "vmguard.config.json"

if (!(Test-Path $ConfigPath)) {
    throw "VMGuard bootstrap failed. vmguard.config.json not found at: $ConfigPath"
}

# ============================================================
# 2. Load Configuration
# ============================================================

$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# ============================================================
# 3. Resolve Paths
# ============================================================

function Resolve-VMGPath($relative) {
    return (Resolve-Path (Join-Path $VMGuardRoot $relative)).Path
}

$Paths = [ordered]@{}
foreach ($k in $Config.paths.PSObject.Properties.Name) {
    $Paths[$k] = Resolve-VMGPath $Config.paths.$k
}

# ============================================================
# 4. Ensure Runtime Directories
# ============================================================

foreach ($p in $Paths.Values) {
    if (!(Test-Path $p)) {
        New-Item -ItemType Directory -Path $p | Out-Null
    }
}

# ============================================================
# 5. Exposed Runtime Object
# ============================================================

$Global:VMGuard = [ordered]@{
    Version     = $Config.vmguard.version
    Root        = $VMGuardRoot
    ConfigPath  = $ConfigPath
    Config      = $Config
    Paths       = $Paths
    Host        = $env:COMPUTERNAME
    User        = $env:USERNAME
    PID         = $PID
    StartTime   = Get-Date
}

# ============================================================
# 6. Bootstrap Banner
# ============================================================

Write-Host "==========================================="
Write-Host " VMGuard Unified Bootstrap v$($VMGuard.Version)"
Write-Host " Root : $($VMGuard.Root)"
Write-Host " PID  : $($VMGuard.PID)"
Write-Host "==========================================="
