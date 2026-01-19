<#
================================================================================
 VMGuard – Bootstrap Loader – v1.1
================================================================================
 Script Name : vmguard-bootstrap.ps1
 Author      : javaboy-vk
 Date        : 2026-01-18
 Version     : 1.1

 PURPOSE
   Establishes the canonical VMGuard runtime context.

   This script is the single authoritative entrypoint for:
     - VMGuard root discovery
     - Central configuration loading
     - Path materialization
     - Canonical exposure of constants, services, and events

 RESPONSIBILITIES
   1) Resolve VMGuard root directory dynamically
   2) Load vmguard.config.json from VMGuard root (canonical)
   3) Validate presence of critical domains
   4) Expose canonical objects: $VMG, $VMGPaths, $VMGEvents, $VMGServices
   5) Provide helper utilities for path resolution
   6) Initialize VMGuard-standard logging bootstrap

 NON-RESPONSIBILITIES
   - Does NOT start services
   - Does NOT perform installs
   - Does NOT control lifecycle
   - Does NOT mutate configuration
   - Does NOT own component logic

 LIFECYCLE CONTEXT
   - MUST be dot-sourced at the top of every VMGuard script
   - MUST succeed for any VMGuard component to continue execution
   - Failure here indicates an invalid or corrupted VMGuard environment
================================================================================
#>

# ============================================================
# 1. VMGuard Root Resolution
# ============================================================

$Global:VMG_BOOTSTRAP_START = Get-Date

try {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

    # Resolve-Path returns a PathInfo; normalize to a string path for Join-Path correctness
    $Global:VMGuardRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
}
catch {
    Write-Host "FATAL: Unable to resolve VMGuard root." -ForegroundColor Red
    exit 1001
}

# ============================================================
# 2. Central Configuration Load
# ============================================================

# Canonical location: VMGuard root
$Global:VMGuardConfigPath = Join-Path $VMGuardRoot "vmguard.config.json"

if (-not (Test-Path $VMGuardConfigPath)) {
    Write-Host "FATAL: vmguard.config.json not found at: $VMGuardConfigPath" -ForegroundColor Red
    exit 1002
}

try {
    $Global:VMG = Get-Content $VMGuardConfigPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "FATAL: Unable to parse vmguard.config.json" -ForegroundColor Red
    exit 1003
}

# ============================================================
# 3. Domain Validation
# ============================================================

$requiredDomains = @("vmguard", "paths", "events", "services")

foreach ($domain in $requiredDomains) {
    if (-not $VMG.$domain) {
        Write-Host "FATAL: Missing required config domain: $domain" -ForegroundColor Red
        exit 1004
    }
}

# ============================================================
# 4. Canonical Object Exposure
# ============================================================

$Global:VMGPaths    = $VMG.paths
$Global:VMGEvents   = $VMG.events
$Global:VMGServices = $VMG.services
$Global:VMGRuntime  = $VMG.runtime

# ============================================================
# 5. Path Resolution Utilities
# ============================================================

function Resolve-VMGPath {
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    return Join-Path $Global:VMGuardRoot $RelativePath
}

function Resolve-VMGConfiguredPath {
    param([Parameter(Mandatory=$true)][string]$ConfigPathValue)
    return Join-Path $Global:VMGuardRoot $ConfigPathValue
}

# ============================================================
# 6. VMGuard Logging Bootstrap
# ============================================================

function Write-VMGBootstrapBanner {

    Write-Host "==========================================="
    Write-Host " VMGuard Bootstrap Loader v1.1"
    Write-Host " Root   : $VMGuardRoot"
    Write-Host " Config : $VMGuardConfigPath"
    Write-Host " Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "==========================================="
}

Write-VMGBootstrapBanner

# ============================================================
# 7. Bootstrap Completion Marker
# ============================================================

$Global:VMG_BOOTSTRAP_COMPLETE = $true
