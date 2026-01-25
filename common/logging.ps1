<#
================================================================================
 VMGuard – Common Logging Module – v1.5
================================================================================
 Module Name : logging.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 1.5

 PURPOSE
   Unified logging to a single file and Windows Application Event Log.

 v1.5 CHANGE
   - Service survivability hardening:
       * Write-Log is non-throwing and never emits Write-Error
       * File logging degrades safely when the log stream/path is unavailable
       * Default log root is anchored from module location (portable)
       * Optional overrides via env.properties/settings.json are best-effort only

 DESIGN RULES
   - Logging is forensic instrumentation.
   - Logging must NEVER terminate Guard/Watcher/Sentinel/Interceptor on STOP.
   - If file logging fails, degrade to console and continue.

================================================================================
#>

# ==============================================================================
# ROOT ANCHORING (portable)
# ==============================================================================
# Default VMGuard root is the parent of the folder containing this module:
#   <root>\common\logging.ps1 => <root>
#
# NOTE:
# - This module must be safe under LocalSystem and during shutdown teardown.
# - Any configuration parsing is best-effort and must not throw.

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

    if ([System.IO.Path]::IsPathRooted($PathValue)) { return $PathValue }
    return (Join-Path $Root $PathValue)
}

# Compute BaseDir as <module-dir>\..
$script:VMG_ModuleDir = $PSScriptRoot
$script:VMG_BaseDir   = $null
try { $script:VMG_BaseDir = (Resolve-Path (Join-Path $script:VMG_ModuleDir "..")).Path } catch { $script:VMG_BaseDir = (Split-Path -Parent $script:VMG_ModuleDir) }

# Optional config overlay locations (best-effort)
$envCandidates = @(
    (Join-Path $script:VMG_BaseDir 'conf\env.properties'),
    (Join-Path $script:VMG_BaseDir 'config\env.properties'),
    (Join-Path $script:VMG_BaseDir 'env.properties')
)
$jsonCandidates = @(
    (Join-Path $script:VMG_BaseDir 'conf\settings.json'),
    (Join-Path $script:VMG_BaseDir 'config\settings.json'),
    (Join-Path $script:VMG_BaseDir 'settings.json')
)

$script:VMG_EnvProps = @{}
$envPath = $envCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($envPath) {
    try { $script:VMG_EnvProps = Import-VMGEnvProperties -Path $envPath } catch { $script:VMG_EnvProps = @{} }
}

$script:VMG_Settings = $null
$jsonPath = $jsonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($jsonPath) {
    try { $script:VMG_Settings = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json } catch { $script:VMG_Settings = $null }
}

# ==============================================================================
# LOG TARGET RESOLUTION
# ==============================================================================
# Default:
#   <root>\logs\vmguard.log
#
# Optional override keys (best-effort):
#   settings.json: logging.file OR vmguard.logging.file OR logging.path
#   env.properties: VMGUARD_LOG_FILE OR VMGUARD_LOG_PATH
#
$defaultLogDir  = Join-Path $script:VMG_BaseDir "logs"
$defaultLogFile = Join-Path $defaultLogDir "vmguard.log"

$cfgLog = $null
try {
    if ($script:VMG_Settings) {
        $cfgLog = (Get-VMGJsonPathValue -Object $script:VMG_Settings -Path "vmguard.logging.file")
        if (-not $cfgLog) { $cfgLog = (Get-VMGJsonPathValue -Object $script:VMG_Settings -Path "logging.file") }
        if (-not $cfgLog) { $cfgLog = (Get-VMGJsonPathValue -Object $script:VMG_Settings -Path "logging.path") }
    }
} catch {}

if (-not $cfgLog) {
    try {
        if ($script:VMG_EnvProps.ContainsKey("VMGUARD_LOG_FILE")) { $cfgLog = $script:VMG_EnvProps["VMGUARD_LOG_FILE"] }
        elseif ($script:VMG_EnvProps.ContainsKey("VMGUARD_LOG_PATH")) { $cfgLog = $script:VMG_EnvProps["VMGUARD_LOG_PATH"] }
    } catch {}
}

if ($cfgLog) { $script:VMG_LogFile = Resolve-VMGMaybeRelativePath -Root $script:VMG_BaseDir -PathValue "$cfgLog" }
else         { $script:VMG_LogFile = $defaultLogFile }

# Create log directory best-effort
try {
    $dir = Split-Path -Parent $script:VMG_LogFile
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue }
} catch {}

# ==============================================================================
# EVENT LOG TARGET
# ==============================================================================
$script:VMG_EventSource = "VMGuard"
$script:VMG_EventLog    = "Application"

# ==============================================================================
# WRITE-LOG (non-throwing)
# ==============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("Information","Warning","Error")][string]$Level = "Information"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0} [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message

    # 1) Best-effort file append (never throw)
    try {
        Add-Content -LiteralPath $script:VMG_LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Degrade to console. DO NOT Write-Error. DO NOT throw.
        try { Write-Host "[VMGuard][LOGGING-DEGRADED] $line" } catch {}
    }

    # 2) Best-effort event log (never throw)
    try {
        $etype = [System.Diagnostics.EventLogEntryType]::Information
        if ($Level -eq "Warning") { $etype = [System.Diagnostics.EventLogEntryType]::Warning }
        if ($Level -eq "Error")   { $etype = [System.Diagnostics.EventLogEntryType]::Error }

        if (-not [System.Diagnostics.EventLog]::SourceExists($script:VMG_EventSource)) {
            # Creating a source can fail under shutdown/permissions; best-effort only.
            try { [System.Diagnostics.EventLog]::CreateEventSource($script:VMG_EventSource, $script:VMG_EventLog) } catch {}
        }

        [System.Diagnostics.EventLog]::WriteEntry($script:VMG_EventSource, $Message, $etype, 1000)
    }
    catch {
        # Degrade silently
    }
}

# ==============================================================================
# VISUAL SEPARATOR (optional helper)
# ==============================================================================
function Write-LogSeparator {
    param([string]$Char = "=",[int]$Width = 43)
    try { Write-Log ($Char * $Width) } catch { }
}
