<#
================================================================================
 VMGuard – Health Check – v1.7
================================================================================
 Script Name : vmguard-healthcheck.ps1
 Author      : javaboy-vk
 Date        : 2026-01-25
 Version     : 1.7

 PURPOSE
   Provide fast diagnostics for VMGuard development and testing.

 v1.7 CHANGE
   - Default user task name aligned to VMGuard-Guard-User

 v1.6 CHANGE
   - Resolve VM name from env.properties when runtime is absent in settings.json

 v1.5 CHANGE
   - PowerShell 5.1 compatibility: removed ternary operator usage.

 v1.4 CHANGE
   - Uses conf\settings.json + conf\env.properties schema as authored.
   - Root resolves from env.properties (VMGUARD_ROOT) when provided.
   - Uses settings.json paths.* for logs/flags/run where applicable.
================================================================================
#>

param(
    [string]$BaseDir = $null,
    [string]$VmName  = $null
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
$PathsLogs        = Get-VMGJsonPathValue -Object $Settings -Path 'paths.logs'
$PathsRun         = Get-VMGJsonPathValue -Object $Settings -Path 'paths.run'
$PathsFlags       = Get-VMGJsonPathValue -Object $Settings -Path 'paths.flags'

if (-not $PathsLogs)  { $PathsLogs  = 'logs' }
if (-not $PathsRun)   { $PathsRun   = 'run' }
if (-not $PathsFlags) { $PathsFlags = 'flags' }


# Allow caller override, otherwise use resolved root
if (-not $BaseDir) { $BaseDir = $VMGuardRoot }

if (-not $VmName) {
    $VmName = Resolve-VMGTargetVmName -Settings $Settings -EnvProps $EnvProps
    if (-not $VmName) { $VmName = 'AtlasW19' }
}

$LogDir  = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $PathsLogs
$FlagDir = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $PathsFlags
$RunDir  = Resolve-VMGMaybeRelativePath -Root $BaseDir -PathValue $PathsRun

$LogFile = Join-Path $LogDir "vmguard-dev-harness.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts - $Message"
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
        Add-Content -Path $LogFile -Value $line
    } catch {}
    Write-Host $line
}

$GuardSvcName = Get-VMGJsonPathValue -Object $Settings -Path 'services.guard.name'
if (-not $GuardSvcName) { $GuardSvcName = 'VMGuard-Guard' }

$UserTaskFolder = Get-VMGJsonPathValue -Object $Settings -Path 'tasks.tasks.userShutdown.folder'
$UserTaskName   = Get-VMGJsonPathValue -Object $Settings -Path 'tasks.tasks.userShutdown.name'
$UserTaskFull   = $null
if ($UserTaskFolder -and $UserTaskName) { $UserTaskFull = "$UserTaskFolder\$UserTaskName" }
if (-not $UserTaskFull) { $UserTaskFull = '\Protepo\VMGuard-Guard-User' }

$StopEventName = Get-VMGJsonPathValue -Object $Settings -Path 'tasks.events.guardStop'
if (-not $StopEventName) { $StopEventName = 'Global\VMGuard_Guard_Stop' }

Write-Log "==========================================="
Write-Log "VMGuard  Health Check  v1.7 (START)"
Write-Log "==========================================="
Write-Log "VMGuardRoot      : $BaseDir"
Write-Log "VmName           : $VmName"
if ($EnvPropsPath) { Write-Log "env.properties   : $EnvPropsPath" } else { Write-Log "env.properties   : [not found]" }
if ($SettingsPath) { Write-Log "settings.json    : $SettingsPath" } else { Write-Log "settings.json    : [not found]" }

# Paths
foreach ($kv in @(
    @{ n='logs';  v=$LogDir  },
    @{ n='flags'; v=$FlagDir },
    @{ n='run';   v=$RunDir  }
)) {
    if (Test-Path $kv.v) { Write-Log "[PASS] Path exists: $($kv.n) => $($kv.v)" }
    else { Write-Log "[WARN] Path missing: $($kv.n) => $($kv.v)" }
}

# Guard service
try {
    $svc = Get-Service -Name $GuardSvcName -ErrorAction Stop
    Write-Log "[PASS] Guard service found: $GuardSvcName (State=$($svc.Status))"
} catch {
    Write-Log "[FAIL] Guard service missing: $GuardSvcName"
}

# Scheduled task
try {
    schtasks /query /tn $UserTaskFull > $null 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log "[PASS] User shutdown task present: $UserTaskFull" }
    else { Write-Log "[WARN] User shutdown task missing: $UserTaskFull" }
} catch {
    Write-Log "[WARN] Unable to query scheduled task (best-effort)."
}

# STOP event accessibility
try {
    $ev = [System.Threading.EventWaitHandle]::OpenExisting($StopEventName)
    Write-Log "[PASS] STOP event openable: $StopEventName"
    $ev.Close()
} catch {
    Write-Log "[WARN] STOP event not openable: $StopEventName"
}

# VM running flag
$flag = Join-Path $FlagDir ("{0}_running.flag" -f $VmName)
if (Test-Path $flag) { Write-Log "[INFO] VM running flag present: $flag" }
else { Write-Log "[INFO] VM running flag not present: $flag" }

Write-Log "==========================================="
Write-Log "VMGuard  Health Check  v1.7 (STOP)"
Write-Log "==========================================="



