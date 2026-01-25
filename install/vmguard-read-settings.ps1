# ============================================================
# VMGuard Read Settings Helper
# Artifact : install\vmguard-read-settings.ps1
# Component: VMGuard / Installer Support
# Version  : 1.4
# Author   : javaboy-vk
# Date     : 2026-01-21
#
# PURPOSE:
#   Read canonical values from conf\settings.json for installer use
#   and emit KEY=VALUE lines to stdout (capture channel):
#     SERVICE_NAME
#     DISPLAY_NAME
#     SERVICE_DESCRIPTION   (optional)
#     LOGS_REL
#     STOP_EVENT
#     WATCHER_SCRIPT_REL
#
# RESPONSIBILITIES:
#   - Validate settings.json existence and parseability
#   - Enforce presence of required keys (no silent defaults)
#   - Emit only capture-safe KEY=VALUE lines to stdout
#
# NON-RESPONSIBILITIES:
#   - No lifecycle control
#   - No STOP signaling
#   - No file generation
#   - No console logging to stdout (stdout is capture channel)
#
# LIFECYCLE CONTEXT:
#   Installer-time configuration extraction (host-side).
#   Must not weaken STOP determinism via implicit fallback behavior.
#
# v1.4 CHANGE SUMMARY
#   - Tightened formatting for <=100 bytes per line.
#   - No behavioral changes.
# ============================================================

param(
  [Parameter(Mandatory = $true)]
  [Alias('S')]
  [string]$SettingsPath
)

# ------------------------------------------------------------
# 1) Logging bootstrap (stderr only; stdout is reserved)
# ------------------------------------------------------------
function Write-VMGStderr {
  param([string]$Msg)

  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
  $p1 = "[{0}] [VMGuard] " -f $ts
  $p2 = "[ReadSettings] {0}" -f $Msg
  [Console]::Error.WriteLine($p1 + $p2)
}

# ------------------------------------------------------------
# 2) Text handling helpers
# ------------------------------------------------------------
function To-NonEmptyText {
  param([object]$Value)

  if ($null -eq $Value) { return $null }
  $t = [string]$Value
  if ([string]::IsNullOrWhiteSpace($t)) { return $null }
  return $t.Trim()
}

# ------------------------------------------------------------
# 3) JSON navigation helpers
# ------------------------------------------------------------
function Get-ByPath {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $cur = $Root
  foreach ($seg in $Path.Split('.')) {
    if ($null -eq $cur) { return $null }
    $p = $cur.PSObject.Properties[$seg]
    if ($null -eq $p) { return $null }
    $cur = $p.Value
  }

  return $cur
}

function Require-Setting {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $v = Get-ByPath -Root $Root -Path $Path
  $t = To-NonEmptyText $v
  if ($t) { return $t }

  Write-VMGStderr ("FATAL: Missing required setting: {0}" -f $Path)
  exit 20
}

function Optional-Setting {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Root,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $v = Get-ByPath -Root $Root -Path $Path
  return (To-NonEmptyText $v)
}

# ------------------------------------------------------------
# 4) Environment and context validation
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
  Write-VMGStderr "FATAL: SettingsPath is empty."
  exit 10
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
  Write-VMGStderr ("FATAL: settings.json not found: {0}" -f $SettingsPath)
  exit 11
}

# ------------------------------------------------------------
# 5) Configuration loading
# ------------------------------------------------------------
try {
  $cfg = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
}
catch {
  Write-VMGStderr ("FATAL: Failed to parse JSON: {0}" -f $SettingsPath)
  exit 12
}

# ------------------------------------------------------------
# 6) Required key extraction (NO DEFAULTS)
# ------------------------------------------------------------
$logsRel = Require-Setting $cfg 'paths.logs'
$stopEvt = Require-Setting $cfg 'events.watcherStop'

$svcName = Require-Setting $cfg 'services.watcher.name'
$disp = Require-Setting $cfg 'services.watcher.displayName'
$scriptRel = Require-Setting $cfg 'services.watcher.script'

$desc = Optional-Setting $cfg 'services.watcher.description'

# ------------------------------------------------------------
# 7) Emit capture lines (stdout only)
# ------------------------------------------------------------
Write-Output ("SERVICE_NAME={0}" -f $svcName)
Write-Output ("DISPLAY_NAME={0}" -f $disp)

if ($desc) {
  Write-Output ("SERVICE_DESCRIPTION={0}" -f $desc)
}

Write-Output ("LOGS_REL={0}" -f $logsRel)
Write-Output ("STOP_EVENT={0}" -f $stopEvt)
Write-Output ("WATCHER_SCRIPT_REL={0}" -f $scriptRel)
exit 0
