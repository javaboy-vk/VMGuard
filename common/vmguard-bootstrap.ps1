<#
================================================================================
 VMGuard – Bootstrap Loader – v1.3
================================================================================
 Script Name : vmguard-bootstrap.ps1
 Author      : javaboy-vk
 Date        : 2026-01-25
 Version     : 1.3

 PURPOSE
   Establish canonical VMGuard runtime context using:
     - conf\env.properties
     - conf\settings.json

 v1.3 CHANGE
   - runtime domain is now optional (env.properties is the sole host input source)
   - Required domain set updated accordingly

 v1.2 CHANGE
   - Compatibility bridging for settings.json schema:
       * events.* legacy consumers are satisfied by tasks.events.* (preferred)
       * tasks.userShutdown.* legacy consumers are satisfied by tasks.tasks.userShutdown.*
       * tasks.hostShutdownInterceptor.* legacy consumers are satisfied by tasks.tasks.hostShutdownInterceptor.*
   - Resolve-VMGPath tolerates empty input (returns $null) so callers can
     implement best-effort defaults without terminating.
================================================================================
#>

# ============================================================
# 1) Utilities
# ============================================================

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

function Resolve-VMGMaybeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $Root $PathValue)
}

function Resolve-VMGPath {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }

    return (Join-Path $Global:VMGuardRoot $PathValue)
}

# ============================================================
# 2) Root Discovery (portable, script-anchored)
# ============================================================

$Global:VMG_BOOTSTRAP_START = Get-Date

try {
    $SelfDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($SelfDir)) { $SelfDir = Split-Path -Parent $PSCommandPath }
    if ([string]::IsNullOrWhiteSpace($SelfDir)) { $SelfDir = (Get-Location).Path }

    # common\ -> root
    $RootCandidate = (Resolve-Path (Join-Path $SelfDir "..")).Path
}
catch {
    Write-Host "FATAL: Unable to resolve VMGuard root from script location." -ForegroundColor Red
    exit 1001
}

# ============================================================
# 3) Config discovery (conf\ preferred; allow config\ and root)
# ============================================================

$envCandidates = @(
    (Join-Path $RootCandidate 'conf\env.properties'),
    (Join-Path $RootCandidate 'config\env.properties'),
    (Join-Path $RootCandidate 'env.properties')
)
$settingsCandidates = @(
    (Join-Path $RootCandidate 'conf\settings.json'),
    (Join-Path $RootCandidate 'config\settings.json'),
    (Join-Path $RootCandidate 'settings.json')
)

$Global:VMGuardEnvPropsPath  = $envCandidates      | Where-Object { Test-Path $_ } | Select-Object -First 1
$Global:VMGuardConfigPath    = $settingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $Global:VMGuardConfigPath) {
    Write-Host "FATAL: settings.json not found. Expected conf\settings.json (preferred)." -ForegroundColor Red
    Write-Host "       RootCandidate: $RootCandidate" -ForegroundColor Yellow
    exit 1002
}

$Global:VMGEnv = @{}
if ($Global:VMGuardEnvPropsPath) {
    try { $Global:VMGEnv = Import-VMGEnvProperties -Path $Global:VMGuardEnvPropsPath } catch { $Global:VMGEnv = @{} }
}

# ============================================================
# 4) Root finalization (env.properties can override)
# ============================================================

if ($Global:VMGEnv.ContainsKey('VMGUARD_ROOT')) {
    $r = $Global:VMGEnv['VMGUARD_ROOT']
    $Global:VMGuardRoot = Resolve-VMGMaybeRelativePath -Root $RootCandidate -PathValue $r
} else {
    $Global:VMGuardRoot = $RootCandidate
}

if (-not (Test-Path $Global:VMGuardRoot)) {
    Write-Host "FATAL: VMGUARD_ROOT does not exist: $Global:VMGuardRoot" -ForegroundColor Red
    exit 1003
}

# ============================================================
# 5) Load settings.json
# ============================================================

try {
    $Global:VMG = Get-Content -LiteralPath $Global:VMGuardConfigPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "FATAL: Failed to parse settings.json: $Global:VMGuardConfigPath" -ForegroundColor Red
    Write-Host "       $($_.Exception.Message)" -ForegroundColor Yellow
    exit 1005
}

# ============================================================
# 6) Domain validation + compatibility bridging
# ============================================================

$requiredDomains = @("vmguard", "paths", "services", "tasks")

foreach ($domain in $requiredDomains) {
    if (-not $Global:VMG.$domain) {
        Write-Host "FATAL: Missing required config domain: $domain" -ForegroundColor Red
        exit 1004
    }
}

# 6.1 events.* legacy compatibility
if (-not $Global:VMG.events) {
    if ($Global:VMG.tasks -and $Global:VMG.tasks.events) {
        try {
            $Global:VMG | Add-Member -MemberType NoteProperty -Name events -Value $Global:VMG.tasks.events -Force
        } catch {}
    }
}
if (-not $Global:VMG.events) {
    Write-Host "FATAL: Missing STOP events domain. Expected either events.* or tasks.events.*" -ForegroundColor Red
    exit 1006
}

# 6.2 tasks.userShutdown / tasks.hostShutdownInterceptor legacy compatibility
# Some installers reference: $VMG.tasks.userShutdown.* (legacy)
# Current schema:          $VMG.tasks.tasks.userShutdown.*
try {
    if ($Global:VMG.tasks -and $Global:VMG.tasks.tasks) {

        if (-not $Global:VMG.tasks.userShutdown -and $Global:VMG.tasks.tasks.userShutdown) {
            $Global:VMG.tasks | Add-Member -MemberType NoteProperty -Name userShutdown -Value $Global:VMG.tasks.tasks.userShutdown -Force
        }

        if (-not $Global:VMG.tasks.hostShutdownInterceptor -and $Global:VMG.tasks.tasks.hostShutdownInterceptor) {
            $Global:VMG.tasks | Add-Member -MemberType NoteProperty -Name hostShutdownInterceptor -Value $Global:VMG.tasks.tasks.hostShutdownInterceptor -Force
        }
    }
} catch {}

# Canonical exports (expected by existing installers/scripts)
$Global:VMGPaths    = $Global:VMG.paths
$Global:VMGServices = $Global:VMG.services
$Global:VMGEvents   = $Global:VMG.events
$Global:VMGRuntime  = $Global:VMG.runtime
$Global:VMGTasks    = $null
try { $Global:VMGTasks = $Global:VMG.tasks.tasks } catch {}

$Global:VMG_BOOTSTRAP_END = Get-Date

# ============================================================
# END OF FILE
# ============================================================

