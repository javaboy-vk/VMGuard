<#
================================================================================
 VMGuard – Interactive Guard Runner – v1.2
================================================================================
 Script Name : vmguard-run-interactive.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 1.2

 PURPOSE
   Run vmguard-service.ps1 interactively for debugging.

 v1.2 CHANGE
   - Guard script path now uses settings.json services.guard.script (relative to root).
   - Root resolves from env.properties (VMGUARD_ROOT) when provided.
================================================================================
#>

param(
    [string]$GuardScript = $null,
    [string]$BaseDir     = $null
)

# ==============================================================================
# PORTABLE ROOT + CONFIG (env.properties + settings.json) – best-effort
# ==============================================================================
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

function Resolve-VMGMaybeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $Root $PathValue)
}

# Anchor candidate root from script location:
#   <root>\dev-harness\*.ps1 => <root>
$VMGuardRootCandidate = $null
try { $VMGuardRootCandidate = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path } catch { $VMGuardRootCandidate = $PSScriptRoot }

# Prefer canonical conf layout (also allow config/ and root)
$envCandidates = @(
    (Join-Path $VMGuardRootCandidate 'conf\env.properties'),
    (Join-Path $VMGuardRootCandidate 'config\env.properties'),
    (Join-Path $VMGuardRootCandidate 'env.properties')
)
$settingsCandidates = @(
    (Join-Path $VMGuardRootCandidate 'conf\settings.json'),
    (Join-Path $VMGuardRootCandidate 'config\settings.json'),
    (Join-Path $VMGuardRootCandidate 'settings.json')
)

$EnvPropsPath = $envCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$SettingsPath = $settingsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

$EnvProps = @{}
if ($EnvPropsPath) {
    try { $EnvProps = Import-VMGEnvProperties -Path $EnvPropsPath } catch { $EnvProps = @{} }
}

$Settings = $null
if ($SettingsPath) {
    try { $Settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json } catch { $Settings = $null }
}

# Resolve VMGuard root (absolute) from env.properties if supplied
$VMGuardRoot = $null
if ($EnvProps.ContainsKey('VMGUARD_ROOT')) {
    $VMGuardRoot = $EnvProps['VMGUARD_ROOT']
} else {
    # settings.json can declare rootMode=relative; we then keep candidate root
    $VMGuardRoot = $VMGuardRootCandidate
}

# Resolve standard path segments from settings.json (relative under root)
$PathsConf        = Get-VMGJsonPathValue -Object $Settings -Path 'paths.conf'
$PathsLogs        = Get-VMGJsonPathValue -Object $Settings -Path 'paths.logs'
$PathsRun         = Get-VMGJsonPathValue -Object $Settings -Path 'paths.run'
$PathsFlags       = Get-VMGJsonPathValue -Object $Settings -Path 'paths.flags'
$PathsDevHarness  = Get-VMGJsonPathValue -Object $Settings -Path 'paths.devHarness'
$PathsGuard       = Get-VMGJsonPathValue -Object $Settings -Path 'paths.guard'
$PathsWatcher     = Get-VMGJsonPathValue -Object $Settings -Path 'paths.watcher'

if (-not $PathsLogs)  { $PathsLogs  = 'logs' }
if (-not $PathsRun)   { $PathsRun   = 'run' }
if (-not $PathsFlags) { $PathsFlags = 'flags' }


if (-not $BaseDir) { $BaseDir = $VMGuardRoot }

if (-not $GuardScript) {
    $rel = Get-VMGJsonPathValue -Object $Settings -Path 'services.guard.script'
    if ($rel) { $GuardScript = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $rel }
    else { $GuardScript = Join-Path $BaseDir "guard\vmguard-service.ps1" }
}

Write-Host "==========================================="
Write-Host "VMGuard  Interactive Guard Runner  v1.2"
Write-Host "==========================================="
Write-Host "VMGuardRoot : $BaseDir"
Write-Host "GuardScript : $GuardScript"

if (-not (Test-Path $GuardScript)) {
    Write-Host "ERROR: Guard script not found: $GuardScript"
    exit 1
}

& $GuardScript -DebugMode
