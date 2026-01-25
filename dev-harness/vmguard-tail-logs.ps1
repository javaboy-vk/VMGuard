<#
================================================================================
 VMGuard – Log Tailer – v1.5
================================================================================
 Script Name : vmguard-tail-logs.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 1.5

 PURPOSE
   VMGuard log inspection and tailing utility.

 v1.5 CHANGE
   - Uses paths.logs from settings.json.
   - Root resolves from env.properties (VMGUARD_ROOT) when provided.
================================================================================
#>

param(
    [ValidateSet("guard","watcher","harness")]
    [string]$Which = "guard",

    [string]$BaseDir = $null,

    [int]$Tail = 60,

    [switch]$Follow,
    [switch]$Observer,

    [int]$WaitTimeout = 10
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
$LogDir = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $PathsLogs

switch ($Which) {
    "guard"   { $log = Join-Path $LogDir "vmguard-guard.log" }
    "watcher" { $log = Join-Path $LogDir "vmguard-watcher.log" }
    "harness" { $log = Join-Path $LogDir "vmguard-dev-harness.log" }
}

Write-Host ""
Write-Host "==========================================="
Write-Host " VMGuard Log Utility"
Write-Host "==========================================="
Write-Host "Target : $Which"
Write-Host "LogDir : $LogDir"
Write-Host "File   : $log"
Write-Host ""

$elapsed = 0
while (-not (Test-Path $log)) {
    if ($elapsed -ge $WaitTimeout) {
        Write-Host "Log file not found after $WaitTimeout seconds."
        return
    }
    Start-Sleep -Seconds 1
    $elapsed++
}

if (-not $Follow -and -not $Observer) {
    Write-Host "-------------------------------------------"
    Write-Host " Last $Tail lines"
    Write-Host "-------------------------------------------"
    Get-Content -Path $log -Tail $Tail
    Write-Host "-------------------------------------------"
    return
}

if ($Follow) {
    Write-Host "-------------------------------------------"
    Write-Host " Following log (Ctrl-C to exit)"
    Write-Host "-------------------------------------------"
    Get-Content -Path $log -Tail $Tail -Wait
    return
}

while ($true) {
    try {
        Get-Content -Path $log -Tail $Tail -Wait
    }
    catch {
        Start-Sleep -Seconds 1
    }
}
