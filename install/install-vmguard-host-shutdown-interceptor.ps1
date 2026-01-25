<#
================================================================================
 VMGuard – Host Shutdown Interceptor Installer (PowerShell) – v1.3
================================================================================
 Script Name : install-vmguard-host-shutdown-interceptor.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 1.3

 PURPOSE
   Install / update the VMGuard Host Shutdown Interceptor Scheduled Task using
   an XML task definition.

   This script owns:
     - VMGuard root resolution (from script location)
     - env.properties validation (conf\env.properties) (no Machine env required)
     - settings.json load (conf\settings.json)
     - Task URI resolution (config-driven)
     - Task XML materialization from template (conf\template-interceptor-task.xml -> conf\interceptor-task.xml)
     - Scheduled Task registration (schtasks)

 DESIGN ALIGNMENT (v1.2)
   The canonical design does NOT use install\templates\ or install\generated\.
   The canonical task template and rendered XML live under conf\:

     conf\template-interceptor-task.xml   (source-controlled template)
     conf\interceptor-task.xml            (rendered output)

   Token substitution is performed during installation.

 PORTABILITY CONTRACT
   - No hard-coded drive letters in source-controlled artifacts
   - Absolute paths may exist only in generated install outputs under VMGuard home
   - No dependency on Machine environment variables
   - No writes outside VMGuard home directory

 CONFIGURATION CONTRACT (TASK NAME)
   Scheduled Task identity MUST come from conf\settings.json.

   Supported config shapes (canonical only):
     A) tasks.hostShutdownInterceptor.uri
        Example: "\Protepo\VMGuard-HostShutdown-Interceptor"TEMPLATE CONTRACT
   The XML template must contain these tokens:
     - __VMGUARD_ROOT__
     - __INTERCEPTOR_SCRIPT__

   Optional tokens supported:
     - __TASK_URI__            (replaced if present)
     - __GUARD_STOP_HELPER__   (resolved from services.guard.stopScript and replaced if present)

================================================================================
#>

# ==============================================================================
# SECTION 0 — ROOT RESOLUTION (INSTALL\ -> VMGUARD\)
# ==============================================================================
$ScriptRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$VMGuardRoot = $null

try {
    $VMGuardRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
}
catch {
    Write-Host "[FATAL] Unable to resolve VMGuard root from install directory." -ForegroundColor Red
    exit 1001
}

# ==============================================================================
# SECTION 0.5 — HOST INPUTS (conf\env.properties) (REQUIRED)
# ==============================================================================
$EnvPropsPath = Join-Path $VMGuardRoot "conf\env.properties"
if (-not (Test-Path -LiteralPath $EnvPropsPath)) {
    Write-Host "[FATAL] Missing required host inputs file: $EnvPropsPath" -ForegroundColor Red
    Write-Host "        Edit conf\env.properties BEFORE running installers." -ForegroundColor Red
    exit 1009
}

function Read-VMGPropertiesFile {
    param([Parameter(Mandatory=$true)][string]$Path)

    $map = @{}
    $lines = Get-Content -LiteralPath $Path -ErrorAction Stop

    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith("#") -or $line.StartsWith(";")) { continue }

        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }

        $k = $line.Substring(0, $idx).Trim()
        $v = $line.Substring($idx + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($k)) { continue }

        $map[$k] = $v
    }

    return $map
}

$envMap = $null
try {
    $envMap = Read-VMGPropertiesFile -Path $EnvPropsPath
} catch {
    Write-Host "[FATAL] Unable to parse env.properties: $EnvPropsPath" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    exit 1009
}

$envRoot = $envMap["VMGUARD_ROOT"]
if ([string]::IsNullOrWhiteSpace($envRoot)) {
    Write-Host "[FATAL] env.properties missing required key: VMGUARD_ROOT" -ForegroundColor Red
    exit 1009
}

try {
    $envRootResolved = (Resolve-Path -LiteralPath $envRoot).Path
} catch {
    Write-Host "[FATAL] VMGUARD_ROOT in env.properties does not resolve: '$envRoot'" -ForegroundColor Red
    exit 1009
}

if ($envRootResolved.TrimEnd("\") -ne $VMGuardRoot.TrimEnd("\")) {
    Write-Host "[FATAL] VMGUARD_ROOT mismatch detected." -ForegroundColor Red
    Write-Host "        Bootstrap root : $VMGuardRoot" -ForegroundColor Red
    Write-Host "        env.properties: $envRootResolved" -ForegroundColor Red
    Write-Host "        Fix env.properties OR run installer from the intended VMGuard root." -ForegroundColor Red
    exit 1009
}

# ==============================================================================
# SECTION 1 — SETTINGS.JSON LOAD (conf\settings.json)
# ==============================================================================
$SettingsPath = Join-Path $VMGuardRoot "conf\settings.json"

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Host "[FATAL] Missing settings.json: $SettingsPath" -ForegroundColor Red
    exit 1002
}

$cfg = $null
try {
    $cfg = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
}
catch {
    Write-Host "[FATAL] Unable to parse settings.json: $SettingsPath" -ForegroundColor Red
    exit 1003
}

# ==============================================================================
# SECTION 2 — TASK URI RESOLUTION (CONFIG-DRIVEN)
# ==============================================================================
function Resolve-TaskUri {
    param(
        [Parameter(Mandatory = $true)]
        $ConfigRoot
    )

    $uri = $null

    if ($ConfigRoot.tasks -and $ConfigRoot.tasks.hostShutdownInterceptor -and $ConfigRoot.tasks.hostShutdownInterceptor.uri) {
        $uri = [string]$ConfigRoot.tasks.hostShutdownInterceptor.uri
    }

    if ([string]::IsNullOrWhiteSpace($uri)) {
        $folder = $null
        $name = $null

        if ($ConfigRoot.tasks -and $ConfigRoot.tasks.hostShutdownInterceptor) {
            if ($ConfigRoot.tasks.hostShutdownInterceptor.folder) { $folder = [string]$ConfigRoot.tasks.hostShutdownInterceptor.folder }
            if ($ConfigRoot.tasks.hostShutdownInterceptor.name)   { $name   = [string]$ConfigRoot.tasks.hostShutdownInterceptor.name }
        }

        if (-not [string]::IsNullOrWhiteSpace($folder) -and -not [string]::IsNullOrWhiteSpace($name)) {
            if (-not $folder.StartsWith("\")) { $folder = "\" + $folder }

            if ($folder.EndsWith("\")) { $uri = $folder + $name }
            else { $uri = $folder + "\" + $name }
        }
    }

    if ([string]::IsNullOrWhiteSpace($uri)) { return $null }
    if (-not $uri.StartsWith("\")) { $uri = "\" + $uri }
    return $uri
}

$TaskUri = Resolve-TaskUri -ConfigRoot $cfg

if (-not $TaskUri) {
    Write-Host "[FATAL] Task identity not found in settings.json." -ForegroundColor Red
    Write-Host "        Expected:" -ForegroundColor Red
    Write-Host "          tasks.hostShutdownInterceptor.uri" -ForegroundColor Red
    Write-Host "        OR:" -ForegroundColor Red
    Write-Host "          tasks.hostShutdownInterceptor.folder + tasks.hostShutdownInterceptor.name" -ForegroundColor Red
    exit 1004
}

# ==============================================================================
# SECTION 2.1 — OPTIONAL: RESOLVE GUARD STOP HELPER (CONFIG-DRIVEN)
# ==============================================================================
$GuardStopHelperAbs = $null
try {
    if ($cfg.services -and $cfg.services.guard -and $cfg.services.guard.stopScript) {
        $rel = [string]$cfg.services.guard.stopScript
        if (-not [string]::IsNullOrWhiteSpace($rel)) {
            $GuardStopHelperAbs = (Join-Path $VMGuardRoot $rel).Trim()
        }
    }
} catch {
    $GuardStopHelperAbs = $null
}

# ==============================================================================
# SECTION 3 — TEMPLATE -> RENDERED XML (conf\template-interceptor-task.xml -> conf\interceptor-task.xml)
# ==============================================================================
$TemplatePath = Join-Path $VMGuardRoot "conf\template-interceptor-task.xml"
$OutXml       = Join-Path $VMGuardRoot "conf\interceptor-task.xml"

# Canonical interceptor script (host shutdown entrypoint)
$InterceptorScript = Join-Path $VMGuardRoot "guard\vmguard-host-shutdown-interceptor.ps1"

Write-Host "==========================================="
Write-Host "VMGuard Host Shutdown Interceptor Installer (PS) v1.2"
Write-Host "==========================================="
Write-Host "VMGuard root : $VMGuardRoot"
Write-Host "EnvProps     : $EnvPropsPath"
Write-Host "Settings     : $SettingsPath"
Write-Host "Task URI     : $TaskUri"
Write-Host "Template XML : $TemplatePath"
Write-Host "Output XML   : $OutXml"
Write-Host "Interceptor  : $InterceptorScript"
if ($GuardStopHelperAbs) { Write-Host "GuardStop    : $GuardStopHelperAbs" }
Write-Host "==========================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $TemplatePath)) {
    Write-Host "[FATAL] Missing template XML: $TemplatePath" -ForegroundColor Red
    exit 1005
}

if (-not (Test-Path -LiteralPath $InterceptorScript)) {
    Write-Host "[FATAL] Missing interceptor script: $InterceptorScript" -ForegroundColor Red
    exit 1005
}

$xml = $null
try {
    $xml = Get-Content -Raw -LiteralPath $TemplatePath
}
catch {
    Write-Host "[FATAL] Unable to read template XML: $TemplatePath" -ForegroundColor Red
    exit 1007
}

# Replace required tokens.
# IMPORTANT: Use env.properties validated root to avoid generating XML pointing at a different tree.
$xml = $xml.Replace("__VMGUARD_ROOT__", $envRootResolved)
$xml = $xml.Replace("__INTERCEPTOR_SCRIPT__", $InterceptorScript)

# Optional token: __TASK_URI__
if ($xml -match "__TASK_URI__") {
    $xml = $xml.Replace("__TASK_URI__", $TaskUri)
}

# Optional token: __GUARD_STOP_HELPER__
if ($GuardStopHelperAbs -and ($xml -match "__GUARD_STOP_HELPER__")) {
    $xml = $xml.Replace("__GUARD_STOP_HELPER__", $GuardStopHelperAbs)
}

# Atomic write (tmp -> replace)
$tmp = "$OutXml.tmp"
try {
    # Scheduled Task XML commonly uses UTF-16. Use Unicode to preserve compatibility.
    $xml | Out-File -FilePath $tmp -Encoding Unicode -Force

    if (Test-Path -LiteralPath $OutXml) {
        Remove-Item -LiteralPath $OutXml -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tmp -Destination $OutXml -Force
}
catch {
    Write-Host "[FATAL] Unable to write rendered XML: $OutXml" -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    exit 1008
}

# ==============================================================================
# SECTION 4 — TASK REGISTRATION (IDEMPOTENT)
# ==============================================================================
& schtasks /Delete /TN "$TaskUri" /F | Out-Null

Write-Host "[INFO] Registering scheduled task..."
& schtasks /Create /TN "$TaskUri" /XML "$OutXml" /F | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] schtasks /Create failed. Run elevated and verify XML." -ForegroundColor Red
    exit 1010
}

Write-Host "[PASS] Task installed/updated."
Write-Host "[INFO] Verifying task registration..."
& schtasks /Query /TN "$TaskUri" /V /FO LIST

if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] Task verification failed." -ForegroundColor Red
    exit 1011
}

Write-Host ""
Write-Host "[DONE] Installation complete."
exit 0

