<#
================================================================================
 VMGuard â€“ Watcher Bootstrap â€“ v1.0
================================================================================
 Script Name : vm-watcher-bootstrap.ps1
 Author      : VMGuard Systems Engineer
 Date        : 2026-01-22
 Version     : 1.0

 PURPOSE
   Bootstrap wrapper for VMGuard Watcher service execution under LocalSystem.
   Imports conf\env.properties into the current process environment, then invokes
   the watcher script (vm-watcher.ps1) in the same PowerShell process.

 DOCTRINE
   - env.properties is the single operator-edited host input file (no machine env vars)
   - fail closed if required keys are missing
   - resolve root relative to script location (portable)
================================================================================
#>

function Import-VMGuardEnvProperties {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string] $EnvPropsPath
  )

  if (-not (Test-Path -LiteralPath $EnvPropsPath)) {
    throw "env.properties missing: $EnvPropsPath"
  }

  $lines = Get-Content -LiteralPath $EnvPropsPath -ErrorAction Stop

  foreach ($raw in $lines) {
    $line = $raw.Trim()
    if ($line.Length -eq 0) { continue }
    if ($line.StartsWith("#") -or $line.StartsWith(";")) { continue }

    # Split only on first '=' (values may contain '=')
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { continue }

    $key = $line.Substring(0, $idx).Trim()
    $val = $line.Substring($idx + 1).Trim()

    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    # Process-only environment population (LocalSystem-safe).
    Set-Item -Path ("Env:{0}" -f $key) -Value $val
  }
}

function Assert-VMGuardEnv {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [string[]] $Keys
  )

  foreach ($k in $Keys) {
    $item = Get-Item -Path ("Env:{0}" -f $k) -ErrorAction SilentlyContinue
    $v = if ($item) { [string]$item.Value } else { "" }
    if ([string]::IsNullOrWhiteSpace($v)) {
      throw "Required VMGuard key not resolved from env.properties: $k"
    }
  }
}

try {
  # Root resolution (portable)
  $WatcherScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
  $VMGuardRoot = Resolve-Path (Join-Path $WatcherScriptRoot "..")
  $EnvPropsPath = Join-Path $VMGuardRoot "conf\env.properties"

  # Import and validate env.properties
  Import-VMGuardEnvProperties -EnvPropsPath $EnvPropsPath

  Assert-VMGuardEnv -Keys @(
    "VMGUARD_ROOT",
    "VMGUARD_ATLAS_VM_DIR",
    "VMGUARD_ATLAS_VMX_PATH",
    "VMGUARD_VMWARE_VMRUN_EXE"
  )

  # Strong consistency: VMGUARD_ROOT in env.properties must match resolved root.
  if (($env:VMGUARD_ROOT.TrimEnd("\") -ne $VMGuardRoot.Path.TrimEnd("\"))) {
    throw "VMGUARD_ROOT mismatch. env.properties='$env:VMGUARD_ROOT' resolvedRoot='$VMGuardRoot'"
  }

  # Invoke Watcher in the same process (service-hosted PowerShell)
  $WatcherPath = Join-Path $WatcherScriptRoot "vm-watcher.ps1"
  if (-not (Test-Path -LiteralPath $WatcherPath)) {
    throw "Watcher script not found: $WatcherPath"
  }

  & $WatcherPath
  exit $LASTEXITCODE
}
catch {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  [Console]::Error.WriteLine("$ts [FATAL] Watcher bootstrap failed: $($_.Exception.Message)")
  [Console]::Error.WriteLine("$ts [FATAL] $($_ | Out-String)")
  exit 1
}
