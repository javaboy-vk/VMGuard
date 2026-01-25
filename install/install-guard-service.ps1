<#
================================================================================
 VMGuard – Guard Service – INSTALL – v2.4
================================================================================
 Script Name : install-guard-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 2.4

 PURPOSE
   Config-driven installer for the VMGuard Guard service.

   v2.0 introduces the canonical host-input file:
     - VMGuard\conf\env.properties

   The installer now:
     - Requires env.properties to exist (edited before any installers run)
     - Loads host absolute paths from env.properties
     - Renders the Host Shutdown Interceptor scheduled task template:
         conf\template-interceptor-task.xml  ->  conf\interceptor-task.xml
       by substituting:
         __VMGUARD_ROOT__
         __INTERCEPTOR_SCRIPT__
     - Installs/updates the Interceptor scheduled task from the rendered XML
     - Logs the rendered path + SHA256 hash in vmguard.log (no XML duplication)

 KEY FIX (v2.1)
   Guard stop helper now supports .cmd stop entrypoint (Procrun StopImage/StopParams auto-wired)
   to allow hardened PID convergence while preserving STOP event signaling via vmguard-guard-stop-event-signal.ps1.


 KEY FIX (v2.2)
   Hardens Host Shutdown Interceptor scheduled task XML before import:
   - Enforces Task schema version baseline (1.2)
   - Enforces LocalSystem ServiceAccount principal (UserId S-1-5-18)
   This resolves schtasks XML import failure at LogonType:ServiceAccount.

 KEY FIX (v2.3)
   Interceptor task rendering now uses XML DOM node-targeted substitution (no comment token corruption)
   and writes a formatted UTF-16 task XML.
   Also removes <LogonType>ServiceAccount</LogonType> to avoid schtasks import rejection on some hosts.

 KEY FIX (v1.15)
   Do NOT re-log external log streams (procrun/stdout/stderr) into vmguard.log.
   - VMGuard file logs must contain exactly one VMGuard level token per line (INFO/WARN/ERROR).
   - External logs may include their own [info]/[error] tokens and must NOT be wrapped into vmguard.log.
   - Diagnostic excerpts remain CONSOLE-ONLY; vmguard.log records only pointers (paths) and VMGuard events.

 KEY FIX (v1.16)
   External stream lines MUST be emitted RAW on console (no VMGuard prefix).

 KEY FIX (v1.18)
   Procrun StartParams/StopParams must be passed as repeated --StartParams/--StopParams entries.
   - Avoids broken "++" tokenization causing PowerShell to receive a single token like:
     -NoProfile++-ExecutionPolicy++Bypass++-File++P:\...

 KEY FIX (v1.19)
   Normalize Apache procrun timestamp bracket format on CONSOLE output:
   - [2026-01-19 14:04:37] [info] ...  ->  2026-01-19 14:04:37 [info] ...
   - Only affects console rendering of external streams; does NOT alter external log files on disk.
   - Procrun install/update output is captured and emitted via the external-stream emitter to apply normalization.

 KEY FIX (v1.20)
   PSScriptAnalyzer compliance:
   - Replaces unapproved verb "Dump-" with approved verb "Export-"
   - Provides backward-compatible alias: Dump-GuardStartDiagnostics -> Export-GuardStartDiagnostics
================================================================================
#>

# ============================================================
# 1. Bootstrap
# ============================================================

. "$PSScriptRoot\..\common\vmguard-bootstrap.ps1"

# ============================================================
# 1.1 Canonical Logging Primitive
# ============================================================

$LoggingModulePath = Join-Path $PSScriptRoot "..\common\logging.ps1"

if (-not (Test-Path $LoggingModulePath)) {
    Write-Host "FATAL: Canonical logging module not found at: $LoggingModulePath" -ForegroundColor Red
    exit 4099
}

. $LoggingModulePath

# Resolve separator from config (fallback preserved)
$Separator = "==========================================="
if ($VMG.logging -and $VMG.logging.separator) { $Separator = $VMG.logging.separator }

# ============================================================
# 2. Resolve Config Domains
# ============================================================

$ServiceName   = $VMGServices.guard.name
$DisplayName   = $VMGServices.guard.displayName
$SentinelSvc   = $VMGServices.sentinel.name

$ServiceDescription = $VMGServices.guard.description
if ([string]::IsNullOrWhiteSpace($ServiceDescription)) { $ServiceDescription = $DisplayName }

$GuardPs1        = Resolve-VMGPath $VMGServices.guard.script
$StopHelper      = Resolve-VMGPath $VMGServices.guard.stopScript
$UserShutdownPs1 = Resolve-VMGPath $VMG.tasks.userShutdown.script

$LogDir      = Resolve-VMGPath $VMGPaths.logs
$RunDir      = Resolve-VMGPath $VMGPaths.run
$Procrun     = Resolve-VMGPath "exe\prunsrv.exe"

$PidFile     = Join-Path $RunDir "VMGuard-Guard.pid"
$PowerShell  = (Get-Command powershell.exe).Source

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }

$Global:VMGuardBaseDir = $VMGuardRoot
$Global:VMGuardLogFile = Join-Path $LogDir "vmguard.log"
$Global:VMGuardSource  = "VMGuard"

# ============================================================
# 2.1 Installer Logging
# ============================================================

function Write-InstallLog {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO",

        [switch]$ConsoleOnly
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$ts [$Level] $Message"

    if (-not $ConsoleOnly) {
        try { Write-Log -Level $Level -Message $Message } catch {}
    }
}

function Write-ExternalStreamLine {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrEmpty($Line)) {
        Write-Host ""
        return
    }

    # v1.19: Normalize ONLY the leading timestamp brackets used by procrun:
    # [2026-01-19 14:04:37] [info] ...  ->  2026-01-19 14:04:37 [info] ...
    $normalized = $Line -replace '^\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]\s+', '$1 '

    # Raw console output: no VMGuard prefix, no extra tokens.
    Write-Host $normalized
}

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Guard Service INSTALL v2.3"
Write-InstallLog -Message "Root   : $VMGuardRoot"
Write-InstallLog -Message "Config : $VMGuardConfigPath"
Write-InstallLog -Message "StopHelper : $StopHelper"
Write-InstallLog -Message $Separator

# ============================================================
# 3. Host Inputs (env.properties) – REQUIRED (v2.0)
# ============================================================

$EnvFile = Join-Path $VMGuardRoot "conf\env.properties"

function Read-VMGPropertiesFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    $map = @{}

    $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
    foreach ($lineRaw in $lines) {

        $line = $lineRaw.Trim()

        if (-not $line) { continue }
        if ($line.StartsWith("#")) { continue }
        if ($line.StartsWith(";")) { continue }

        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { continue }

        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1).Trim()

        if (-not $k) { continue }

        $map[$k] = $v
    }

    return $map
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-InstallLog -Level "ERROR" -Message "Missing required host inputs file: $EnvFile"
    Write-InstallLog -Level "ERROR" -Message "Edit/create conf\env.properties BEFORE running installers."
    exit 4013
}

$VMGEnv = $null
try {
    $VMGEnv = Read-VMGPropertiesFile -Path $EnvFile
} catch {
    Write-InstallLog -Level "ERROR" -Message "Unable to parse env.properties at: $EnvFile"
    Write-InstallLog -Level "ERROR" -Message "$($_.Exception.Message)"
    exit 4013
}

$EnvRoot = $VMGEnv["VMGUARD_ROOT"]
if ([string]::IsNullOrWhiteSpace($EnvRoot)) {
    Write-InstallLog -Level "ERROR" -Message "env.properties missing required key: VMGUARD_ROOT"
    exit 4013
}

# Enforce that env.properties root matches the actual script-resolved root.
# This avoids installing a scheduled task pointing at the wrong VMGuard tree.
try {
    $EnvRootResolved = (Resolve-Path -LiteralPath $EnvRoot).Path
} catch {
    Write-InstallLog -Level "ERROR" -Message "VMGUARD_ROOT in env.properties does not resolve: '$EnvRoot'"
    exit 4013
}

if ($EnvRootResolved.TrimEnd("\") -ne $VMGuardRoot.TrimEnd("\")) {
    Write-InstallLog -Level "ERROR" -Message "VMGUARD_ROOT mismatch detected."
    Write-InstallLog -Level "ERROR" -Message "  Bootstrap root : $VMGuardRoot"
    Write-InstallLog -Level "ERROR" -Message "  env.properties: $EnvRootResolved"
    Write-InstallLog -Level "ERROR" -Message "Fix env.properties OR run installer from the intended VMGuard root."
    exit 4013
}

Write-InstallLog -Message "env.properties loaded and validated: $EnvFile"
Write-InstallLog -Message "VMGUARD_ROOT (validated)          : $EnvRootResolved"

# ============================================================
# 4. Hard Validation
# ============================================================

$required = @($Procrun,$GuardPs1,$StopHelper,$UserShutdownPs1)
foreach ($item in $required) {
    if (-not (Test-Path $item)) {
        Write-InstallLog -Level "ERROR" -Message "Required artifact missing: $item"
        exit 4001
    }
}

# ============================================================
# 5. Host Shutdown Interceptor Task (template -> rendered -> installed) (v2.0)
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Host Shutdown Interceptor Task (Template Render + Install)"
Write-InstallLog -Message $Separator

# Canonical template and rendered paths (operator edits template only via source control).
$InterceptorTemplate = Join-Path $VMGuardRoot "conf\template-interceptor-task.xml"
$InterceptorRendered = Join-Path $VMGuardRoot "conf\interceptor-task.xml"

# Canonical interceptor script (host shutdown entrypoint)
$InterceptorScript = Join-Path $VMGuardRoot "guard\vmguard-host-shutdown-interceptor.ps1"

# Best-effort legacy fallback for template (transition only)
$LegacyTemplate = Join-Path $VMGuardRoot "install\vmguard-host-shutdown-interceptor-task.xml"

if (-not (Test-Path -LiteralPath $InterceptorTemplate)) {
    if (Test-Path -LiteralPath $LegacyTemplate) {
        Write-InstallLog -Level "WARN" -Message "Template not found at canonical location: $InterceptorTemplate"
        Write-InstallLog -Level "WARN" -Message "Using legacy fallback template: $LegacyTemplate"
        $InterceptorTemplate = $LegacyTemplate
    } else {
        Write-InstallLog -Level "ERROR" -Message "Interceptor task template not found."
        Write-InstallLog -Level "ERROR" -Message "  Expected: $InterceptorTemplate"
        Write-InstallLog -Level "ERROR" -Message "  Fallback: $LegacyTemplate"
        exit 4014
    }
}

if (-not (Test-Path -LiteralPath $InterceptorScript)) {
    Write-InstallLog -Level "ERROR" -Message "Required interceptor script not found: $InterceptorScript"
    exit 4014
}

# Render tokens
try {
    $xmlRaw = Get-Content -LiteralPath $InterceptorTemplate -Raw
} catch {
    Write-InstallLog -Level "ERROR" -Message "Unable to read interceptor task template: $InterceptorTemplate"
    exit 4014
}

# Render tokens (node-targeted; preserve template comment documentation)
# We do NOT do blind string Replace() on the full template because __VMGUARD_ROOT__/__INTERCEPTOR_SCRIPT__
# appear in the template comment block as documentation tokens.

# -----------------------------------------------------------------------------
# v2.3 HARDENING: DOM-based task rendering (preserve template, avoid schtasks rejection)
# -----------------------------------------------------------------------------
# Goals:
#   - Replace tokens ONLY in the intended nodes (Arguments / WorkingDirectory / Description)
#     and DO NOT corrupt comment token documentation.
#   - Preserve readable, multi-line task XML on disk (forensics / operator sanity).
#   - Enforce LocalSystem principal and remove LogonType=ServiceAccount (some schtasks builds reject it).
# -----------------------------------------------------------------------------

function Render-InterceptorTaskXml {
    param(
        [Parameter(Mandatory=$true)][string]$TemplatePath,
        [Parameter(Mandatory=$true)][string]$OutPath,
        [Parameter(Mandatory=$true)][string]$VMGuardRootAbs,
        [Parameter(Mandatory=$true)][string]$InterceptorScriptAbs
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Template not found: $TemplatePath"
    }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($TemplatePath)

    $nsUri = $doc.DocumentElement.NamespaceURI
    $nsMgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    if (-not [string]::IsNullOrWhiteSpace($nsUri)) {
        $nsMgr.AddNamespace("t", $nsUri)
    }

    # Token substitution (node-targeted)
    $argsNode = $doc.SelectSingleNode("/t:Task/t:Actions/t:Exec/t:Arguments", $nsMgr)
    if ($argsNode) { $argsNode.InnerText = $argsNode.InnerText.Replace("__INTERCEPTOR_SCRIPT__", $InterceptorScriptAbs) }

    $wdNode = $doc.SelectSingleNode("/t:Task/t:Actions/t:Exec/t:WorkingDirectory", $nsMgr)
    if ($wdNode) { $wdNode.InnerText = $wdNode.InnerText.Replace("__VMGUARD_ROOT__", $VMGuardRootAbs) }

    $descNode = $doc.SelectSingleNode("/t:Task/t:RegistrationInfo/t:Description", $nsMgr)
    if ($descNode) {
        $descNode.InnerText = $descNode.InnerText.Replace("__INTERCEPTOR_SCRIPT__", $InterceptorScriptAbs)
        $descNode.InnerText = $descNode.InnerText.Replace("__VMGUARD_ROOT__", $VMGuardRootAbs)
    }

    # Principal hardening (LocalSystem)
    $principal = $doc.SelectSingleNode("/t:Task/t:Principals/t:Principal", $nsMgr)
    if ($principal) {
        $userId = $principal.SelectSingleNode("t:UserId", $nsMgr)
        if (-not $userId) {
            $userId = $doc.CreateElement("UserId", $nsUri)
            [void]$principal.AppendChild($userId)
        }
        $userId.InnerText = "S-1-5-18"

        # Remove LogonType to maximize schtasks import compatibility.
        $logonType = $principal.SelectSingleNode("t:LogonType", $nsMgr)
        if ($logonType) { [void]$principal.RemoveChild($logonType) }

        $runLevel = $principal.SelectSingleNode("t:RunLevel", $nsMgr)
        if (-not $runLevel) {
            $runLevel = $doc.CreateElement("RunLevel", $nsUri)
            [void]$principal.AppendChild($runLevel)
        }
        $runLevel.InnerText = "HighestAvailable"
    }

    # Write formatted UTF-16 task XML
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.IndentChars = "  "
    $settings.NewLineChars = "`r`n"
    $settings.NewLineHandling = "Replace"
    $settings.OmitXmlDeclaration = $false
    $settings.Encoding = [System.Text.Encoding]::Unicode

    $writer = [System.Xml.XmlWriter]::Create($OutPath, $settings)
    $doc.Save($writer)
    $writer.Close()
}

# Atomic write (tmp -> replace)
$tmp = "$InterceptorRendered.tmp"
try {
    # Render via DOM and write formatted UTF-16 to temp path (atomic replace pattern)
    Render-InterceptorTaskXml -TemplatePath $InterceptorTemplate `
                              -OutPath $tmp `
                              -VMGuardRootAbs $EnvRootResolved `
                              -InterceptorScriptAbs $InterceptorScript

    if (Test-Path -LiteralPath $InterceptorRendered) {
        Remove-Item -LiteralPath $InterceptorRendered -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tmp -Destination $InterceptorRendered -Force

    $hash = (Get-FileHash -LiteralPath $InterceptorRendered -Algorithm SHA256).Hash
    Write-InstallLog -Message "Interceptor task rendered:"
    Write-InstallLog -Message "  Template : $InterceptorTemplate"
    Write-InstallLog -Message "  Output   : $InterceptorRendered"
    Write-InstallLog -Message "  SHA256   : $hash"
} catch {
    Write-InstallLog -Level "ERROR" -Message "Failed to render interceptor task XML to: $InterceptorRendered"
    Write-InstallLog -Level "ERROR" -Message "$($_.Exception.Message)"
    exit 4014
}

# Task name should match the XML URI. Canonical VMGuard name:
$InterceptorTaskName = "\Protepo\VMGuard-HostShutdown-Interceptor"

# Install/update from XML (idempotent via /F)
try {
    $out = & schtasks /Create /TN "$InterceptorTaskName" /XML "$InterceptorRendered" /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-InstallLog -Level "ERROR" -Message "Failed to create/update interceptor task: $InterceptorTaskName"
        $out | ForEach-Object { Write-ExternalStreamLine -Line $_ }
        exit 4015
    }

    Write-InstallLog -Message "Interceptor task installed/updated: $InterceptorTaskName"

    schtasks /query /tn "$InterceptorTaskName" >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-InstallLog -Level "ERROR" -Message "Interceptor task validation failed: $InterceptorTaskName"
        exit 4015
    }

    Write-InstallLog -Message "Interceptor task validated."
} catch {
    Write-InstallLog -Level "ERROR" -Message "Interceptor task enforcement failed: $($_.Exception.Message)"
    exit 4015
}

# ============================================================
# 6. Scheduled Task Enforcement (User Shutdown Task)
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Scheduled Task Enforcement (User Shutdown)"
Write-InstallLog -Message $Separator

$TaskName = "$($VMG.tasks.userShutdown.folder)\$($VMG.tasks.userShutdown.name)"
schtasks /query /tn "$TaskName" >$null 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-InstallLog -Message "Scheduled task not found. Creating..."

    schtasks /create `
      /tn "$TaskName" `
      /sc ONCE /st 00:00 /f `
      /tr "`"$PowerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$UserShutdownPs1`"" `
      /rl HIGHEST /it

    if ($LASTEXITCODE -ne 0) {
        Write-InstallLog -Level "ERROR" -Message "Failed to create scheduled task: $TaskName"
        exit 4002
    }
}

schtasks /query /tn "$TaskName" >$null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-InstallLog -Level "ERROR" -Message "Scheduled task validation failed."
    exit 4003
}

Write-InstallLog -Message "Scheduled task installed and validated."

# ============================================================
# 7. Sentinel Precheck (presence + running state)
#    + Enforce Sentinel AUTO_START
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Preshutdown Sentinel Precheck"
Write-InstallLog -Message $Separator

$sentinel = Get-Service -Name $SentinelSvc -ErrorAction SilentlyContinue
if (-not $sentinel) {
    Write-InstallLog -Level "ERROR" -Message "Required preshutdown service not found: $SentinelSvc"
    exit 4004
}

try {
    $sentinelCim = Get-CimInstance Win32_Service -Filter "Name='$SentinelSvc'" -ErrorAction Stop
    if ($sentinelCim.StartMode -ne "Auto") {
        Write-InstallLog -Level "WARN" -Message "Sentinel StartMode is '$($sentinelCim.StartMode)'. Enforcing AUTO_START."
        $scOut = & "$env:SystemRoot\System32\sc.exe" config $SentinelSvc "start=" "auto" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-InstallLog -Level "ERROR" -Message "Failed to enforce Sentinel AUTO_START. $scOut"
            exit 4004
        }
    }
} catch {
    Write-InstallLog -Level "WARN" -Message "Unable to validate/enforce Sentinel StartMode via CIM. Proceeding. $_"
}

if ($sentinel.Status -ne "Running") {
    try {
        Start-Service -Name $SentinelSvc -ErrorAction Stop
        $sentinel = Get-Service -Name $SentinelSvc -ErrorAction Stop
        if ($sentinel.Status -ne "Running") { throw "Sentinel did not reach Running. CurrentStatus=$($sentinel.Status)" }
        Write-InstallLog -Message "Sentinel service started."
    } catch {
        Write-InstallLog -Level "ERROR" -Message "Failed to start preshutdown sentinel service '$SentinelSvc'. $_"
        exit 4004
    }
} else {
Write-InstallLog -Message "Sentinel service already running."
}

# ============================================================
# 8.0 Bounded Stop Helper (avoid hangs on stale stop config)
# ============================================================

function Stop-VMGServiceBounded {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [int]$WaitSeconds = 10
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $true }
    if ($svc.Status -eq "Stopped") { return $true }

    Write-InstallLog -Message "Requesting existing service stop prior to update..."

    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
    } catch {
        Write-InstallLog -Level "WARN" -Message "Stop-Service failed (will attempt PID kill): $_"
    }

    try {
        $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds($WaitSeconds)) | Out-Null
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Stopped") { return $true }
    } catch {
        # Continue to PID kill below.
    }

    Write-InstallLog -Level "WARN" -Message "Service did not stop within ${WaitSeconds}s. Attempting PID termination."

    $svcPid = $null
    try {
        $pidLine = sc.exe queryex $Name | findstr /I "PID"
        if ($pidLine -match 'PID\s*:\s*(\d+)') { $svcPid = [int]$matches[1] }
    } catch {}

    if ($svcPid -and $svcPid -gt 0) {
        try {
            taskkill /PID $svcPid /T /F > $null 2>&1
        } catch {}
    }

    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    return (-not $svc -or $svc.Status -eq "Stopped")
}

# ============================================================
# 8. Install / Update Guard Service (idempotent)
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "Installing / Updating $ServiceName"
Write-InstallLog -Message $Separator

$existingSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$procrunVerb = "IS"
if ($existingSvc) { $procrunVerb = "US" }

if ($existingSvc) {
    Write-InstallLog -Message "Service exists. Performing UPDATE via procrun (//US//)."
    $stopped = Stop-VMGServiceBounded -Name $ServiceName -WaitSeconds 12
    if (-not $stopped) {
        Write-InstallLog -Level "WARN" -Message "Unable to stop existing service prior to update. Proceeding."
    }
} else {
    Write-InstallLog -Message "Service not present. Performing INSTALL via procrun (//IS//)."
}

# v1.19: Capture procrun output so we can normalize bracketed timestamps on console
# v2.1: StopHelper may be .cmd/.bat (cmd.exe /c) or .ps1 (powershell.exe -File). Auto-wire deterministically.

$stopExt = [System.IO.Path]::GetExtension($StopHelper).ToLowerInvariant()
$StopImage = $null
$StopParams = @()

if ($stopExt -eq ".ps1") {
    $StopImage = $PowerShell
    $StopParams += "-NoProfile"
    $StopParams += "-ExecutionPolicy"
    $StopParams += "Bypass"
    $StopParams += "-File"
    $StopParams += $StopHelper
} else {
    $StopImage = $env:ComSpec
    $StopParams += "/c"
    $StopParams += $StopHelper
}

Write-InstallLog -Message "StopImage : $StopImage"
Write-InstallLog -Message ("StopParams: " + ($StopParams -join " "))

$procrunArgs = @(
  ("//{0}//{1}" -f $procrunVerb, $ServiceName),
  ("--DisplayName={0}" -f $DisplayName),
  ("--Description={0}" -f $ServiceDescription),
  "--Startup=auto",
  "--StartMode=exe",
  ("--StartImage={0}" -f $PowerShell),
  "--StartParams=-NoProfile",
  "--StartParams=-ExecutionPolicy",
  "--StartParams=Bypass",
  "--StartParams=-File",
  ("--StartParams={0}" -f $GuardPs1),
  ("--StartPath={0}" -f $VMGuardRoot),

  "--StopMode=exe",
  ("--StopImage={0}" -f $StopImage),
  ("--StopTimeout=120"),
  ("--PidFile={0}" -f $PidFile),

  "--ServiceUser=LocalSystem",

  ("--LogPath={0}" -f $LogDir),
  "--LogPrefix=VMGuard-Guard-procrun",
  "--LogLevel=Info",
  ("--StdOutput={0}" -f (Join-Path $LogDir "VMGuard-Guard-stdout.log")),
  ("--StdError={0}" -f (Join-Path $LogDir "VMGuard-Guard-stderr.log"))
)

foreach ($p in $StopParams) {
  $procrunArgs += ("--StopParams={0}" -f $p)
}

$procrunOut = & "$Procrun" @procrunArgs 2>&1
$procrunExit = $LASTEXITCODE

# Emit procrun output as external stream (RAW, normalized timestamp brackets)
$procrunOut | ForEach-Object { Write-ExternalStreamLine -Line $_ }

if ($procrunExit -ne 0) {
    Write-InstallLog -Level "ERROR" -Message "Service install/update failed via procrun (//${procrunVerb}//). ExitCode=$procrunExit"
    exit 4010
}

# ============================================================
# 8.1 Sentinel Dependency Enforcement
# ============================================================

Write-InstallLog -Message $Separator
Write-InstallLog -Message "VMGuard Preshutdown Sentinel Dependency Wiring"
Write-InstallLog -Message $Separator

try {
    $scOut = & "$env:SystemRoot\System32\sc.exe" config $ServiceName "depend=" "$SentinelSvc" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed (ExitCode=$LASTEXITCODE): $scOut" }

    $qc = & "$env:SystemRoot\System32\sc.exe" qc $ServiceName 2>&1
    Write-InstallLog -Message "Sentinel dependency enforced."
    Write-InstallLog -Message "--- sc.exe qc $ServiceName (dependency verification) ---"
    $qc | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Message $_ } }
}
catch {
    Write-InstallLog -Level "ERROR" -Message "Failed to set service dependency. $_"
    & "$Procrun" //DS//$ServiceName >$null 2>&1
    exit 4005
}

# ============================================================
# 9. Guardrail — LocalSystem enforcement
# ============================================================

try {
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
} catch {
    Write-InstallLog -Level "ERROR" -Message "Unable to query service '$ServiceName' for StartName. $_"
    exit 4011
}

if ($svc.StartName -ne "LocalSystem") {
    Write-InstallLog -Level "ERROR" -Message "Service is NOT LocalSystem (StartName='$($svc.StartName)'). Rolling back."
    & "$Procrun" //DS//$ServiceName >$null 2>&1
    exit 4011
}

Write-InstallLog -Message "Service account validated: LocalSystem"

# ============================================================
# 10. Start Service (with diagnostics on failure)
# ============================================================

function Export-GuardStartDiagnostics {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$SentinelSvc,
        [Parameter(Mandatory=$true)][string]$LogDir,
        [Parameter(Mandatory=$true)][string]$Separator
    )

    Write-InstallLog -Level "ERROR" -Message $Separator
    Write-InstallLog -Level "ERROR" -Message "VMGuard Guard START FAILURE DIAGNOSTICS"
    Write-InstallLog -Level "ERROR" -Message $Separator

    try {
        Write-InstallLog -Level "ERROR" -Message "--- sc.exe qc (Guard) ---"
        (& "$env:SystemRoot\System32\sc.exe" qc $ServiceName 2>&1) | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Level "ERROR" -Message $_ }
        }
    } catch {}

    try {
        Write-InstallLog -Level "ERROR" -Message "--- sc.exe qc (Sentinel) ---"
        (& "$env:SystemRoot\System32\sc.exe" qc $SentinelSvc 2>&1) | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) { Write-InstallLog -Level "ERROR" -Message $_ }
        }
    } catch {}

    try {
        $s = Get-Service -Name $SentinelSvc -ErrorAction Stop
        Write-InstallLog -Level "ERROR" -Message "Sentinel Status : $($s.Status)"
        Write-InstallLog -Level "ERROR" -Message "Sentinel Name   : $($s.Name)"
        Write-InstallLog -Level "ERROR" -Message "Sentinel Display: $($s.DisplayName)"
    } catch {}

    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
        Write-InstallLog -Level "ERROR" -Message "ServiceName              : $($svc.Name)"
        Write-InstallLog -Level "ERROR" -Message "State                    : $($svc.State)"
        Write-InstallLog -Level "ERROR" -Message "StartMode                : $($svc.StartMode)"
        Write-InstallLog -Level "ERROR" -Message "StartName                : $($svc.StartName)"
        Write-InstallLog -Level "ERROR" -Message "PathName                 : $($svc.PathName)"
        Write-InstallLog -Level "ERROR" -Message "ExitCode                 : $($svc.ExitCode)"
        Write-InstallLog -Level "ERROR" -Message "ServiceSpecificExitCode  : $($svc.ServiceSpecificExitCode)"
    } catch {}

    try {
        $stdOut = Join-Path $LogDir "VMGuard-Guard-stdout.log"
        $stdErr = Join-Path $LogDir "VMGuard-Guard-stderr.log"

        Write-InstallLog -Level "ERROR" -Message "LogDir  : $LogDir"
        Write-InstallLog -Level "ERROR" -Message "STDOUT  : $stdOut"
        Write-InstallLog -Level "ERROR" -Message "STDERR  : $stdErr"
        Write-InstallLog -Level "ERROR" -Message "PROCRUN : (see VMGuard-Guard-procrun*.log under LogDir)"

        if (Test-Path $stdOut) {
            Write-InstallLog -Level "ERROR" -Message "--- STDOUT (last 200 lines, RAW console) ---" -ConsoleOnly
            Get-Content $stdOut -Tail 200 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
            }
        }

        if (Test-Path $stdErr) {
            Write-InstallLog -Level "ERROR" -Message "--- STDERR (last 200 lines, RAW console) ---" -ConsoleOnly
            Get-Content $stdErr -Tail 200 | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
            }
        }

        $procrunLogs = Get-ChildItem -Path $LogDir -Filter "VMGuard-Guard-procrun*.log" -ErrorAction SilentlyContinue |
                       Sort-Object LastWriteTime -Descending |
                       Select-Object -First 3

        if ($procrunLogs) {
            $names = ($procrunLogs | ForEach-Object { $_.FullName }) -join "; "
            Write-InstallLog -Level "ERROR" -Message "PROCRUN (latest 3): $names"

            foreach ($f in $procrunLogs) {
                Write-InstallLog -Level "ERROR" -Message "--- PROCRUN LOG (RAW console): $($f.FullName) (last 200 lines) ---" -ConsoleOnly
                Get-Content $f.FullName -Tail 200 | ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace($_)) { Write-ExternalStreamLine -Line $_ }
                }
            }
        }
    } catch {}

    try {
        Write-InstallLog -Level "ERROR" -Message "--- Service Control Manager (System log, last 15 events) ---"
        Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Service Control Manager' } -MaxEvents 15 |
            ForEach-Object {
                $msg = $_.Message -replace "`r`n"," | "
                Write-InstallLog -Level "ERROR" -Message "$($_.TimeCreated) :: $msg"
            }
    } catch {}
}

# Backward compatibility: keep legacy name without reintroducing analyzer violation
Set-Alias -Name Dump-GuardStartDiagnostics -Value Export-GuardStartDiagnostics

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 2

    $gs = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($gs.Status -ne "Running") { throw "Service transitioned to '$($gs.Status)' shortly after start." }
}
catch {
    Write-InstallLog -Level "ERROR" -Message "Failed to start service '$ServiceName' or it did not remain Running. $_"
    Export-GuardStartDiagnostics -ServiceName $ServiceName -SentinelSvc $SentinelSvc -LogDir $LogDir -Separator $Separator
    exit 4012
}

Write-InstallLog -Message "Service started and validated (Running): $ServiceName"

Write-InstallLog -Message $Separator
Write-InstallLog -Message "INSTALL COMPLETE"
Write-InstallLog -Message $Separator

exit 0

