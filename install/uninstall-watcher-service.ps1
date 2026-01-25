<##
================================================================================
 VMGuard - Watcher Service - UNINSTALL - v2.2
================================================================================
 Script Name : uninstall-watcher-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-25
 Version     : 2.2

 PURPOSE
   Uninstall the VMGuard Watcher service using Apache Procrun (prunsrv.exe).

 PORTABILITY
   - Anchors VMGuard root relative to this installer location.
   - Uses conf\env.properties + conf\settings.json via vmguard-bootstrap.ps1.
================================================================================
#>

$ErrorActionPreference = 'Stop'

$Bootstrap = Join-Path $PSScriptRoot '..\common\vmguard-bootstrap.ps1'
$Bootstrap = (Resolve-Path $Bootstrap).Path
. $Bootstrap

$SvcName   = $VMGServices.watcher.name
if (-not $SvcName) { $SvcName = 'VMGuard-Watcher' }

$Procrun   = Resolve-VMGPath 'exe\prunsrv.exe'

Write-Host ''
Write-Host '==========================================='
Write-Host ' VMGuard Watcher Service UNINSTALL v2.2'
Write-Host '==========================================='
Write-Host "Root    : $VMGuardRoot"
Write-Host "Service : $SvcName"
Write-Host "Procrun : $Procrun"
Write-Host ''

if (-not (Test-Path $Procrun)) {
    Write-Host "[FATAL] prunsrv.exe not found: $Procrun" -ForegroundColor Red
    exit 4101
}

# Stop best-effort
try { sc.exe stop $SvcName > $null 2>&1 } catch {}

Start-Sleep -Seconds 1

Write-Host "[INFO] Uninstalling $SvcName via procrun..."
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$procrunOut = & $Procrun ("//DS//{0}" -f $SvcName) 2>&1
$procrunExit = $LASTEXITCODE
$ErrorActionPreference = $oldEap

if ($procrunExit -ne 0) {
    $msg = ($procrunOut -join ' ')
    if ($msg -match 'does not exist' -or $procrunExit -eq 9) {
        Write-Host "[WARN] Procrun reported missing service. Continuing." -ForegroundColor Yellow
    } else {
        Write-Host "[FATAL] Procrun uninstall failed. ExitCode=$procrunExit" -ForegroundColor Red
        $procrunOut | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { Write-Host $_ } }
        exit 4102
    }
}

# Verify removal with retries (SCM lag)
$removed = $false
for ($i=0; $i -lt 5; $i++) {
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if (-not $svc) { $removed = $true; break }
    Start-Sleep -Seconds 1
}

if ($removed) {
    Write-Host "[PASS] Service removed: $SvcName"
} else {
    Write-Host "[WARN] Service still queryable after uninstall (SCM cache). Reboot may be required." -ForegroundColor Yellow
}

Write-Host ''
Write-Host '[SUCCESS] VMGuard Watcher uninstalled.'
exit 0
