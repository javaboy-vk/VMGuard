<#
================================================================================
 VMGuard – Simulate VM Running State – v1.4
================================================================================
 Script Name : vmguard-simulate-vm-running.ps1
 Author      : javaboy-vk
 Date        : 2026-01-25
 Version     : 1.4

 PURPOSE
   Deterministically simulate VM running state via flag file.

 v1.4 CHANGE
   - Resolve VM name from env.properties when runtime is absent in settings.json

 v1.3 CHANGE
   - Uses runtime.targetVm.name from settings.json.
   - Uses paths.flags from settings.json.
   - Root resolves from env.properties (VMGUARD_ROOT) when provided.
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("on","off","status")]
    [string]$Mode = "status",

    [Parameter(Mandatory = $false)]
    [string]$VmName  = $null,

    [Parameter(Mandatory = $false)]
    [string]$BaseDir = $null
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

function Resolve-VMGTargetVmName {
    param(
        [object]$Settings,
        [hashtable]$EnvProps
    )

    $name = Get-VMGJsonPathValue -Object $Settings -Path 'runtime.targetVm.name'
    if (-not [string]::IsNullOrWhiteSpace($name)) { return $name }

    if ($EnvProps -and $EnvProps.ContainsKey('VMGUARD_ATLAS_VM_NAME')) {
        $name = "$($EnvProps['VMGUARD_ATLAS_VM_NAME'])".Trim()
        if ($name.Length -gt 0) { return $name }
    }

    if ($EnvProps -and $EnvProps.ContainsKey('VMGUARD_ATLAS_VMX_PATH')) {
        $vmx = "$($EnvProps['VMGUARD_ATLAS_VMX_PATH'])".Trim()
        if ($vmx.Length -gt 0) { return [System.IO.Path]::GetFileNameWithoutExtension($vmx) }
    }

    if ($EnvProps -and $EnvProps.ContainsKey('VMGUARD_ATLAS_VM_DIR')) {
        $dir = "$($EnvProps['VMGUARD_ATLAS_VM_DIR'])".Trim()
        if ($dir.Length -gt 0) { return Split-Path -Leaf $dir }
    }

    return $null
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

if (-not $VmName) {
    $VmName = Resolve-VMGTargetVmName -Settings $Settings -EnvProps $EnvProps
    if (-not $VmName) { $VmName = 'AtlasW19' }
}

$FlagDir  = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $PathsFlags
$FlagFile = Join-Path $FlagDir ("{0}_running.flag" -f $VmName)

New-Item -ItemType Directory -Force -Path $FlagDir | Out-Null

switch ($Mode) {
    "on" {
        Set-Content -Path $FlagFile -Value "VMGuard simulated running: $(Get-Date)" -Force
        Write-Host "SIMULATION: VM marked RUNNING."
    }
    "off" {
        if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force -ErrorAction SilentlyContinue }
        Write-Host "SIMULATION: VM marked NOT RUNNING."
    }
    "status" {
        if (Test-Path $FlagFile) { Write-Host "STATUS: RUNNING" }
        else { Write-Host "STATUS: NOT RUNNING" }
    }
}

