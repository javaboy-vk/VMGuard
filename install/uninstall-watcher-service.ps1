<#
================================================================================
 VMGuard – Watcher Service – UNINSTALL – v2.0
================================================================================
 Script Name : uninstall-watcher-service.ps1
 Author      : javaboy-vk
 Date        : 2026-01-23
 Version     : 2.0

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
Write-Host ' VMGuard Watcher Service UNINSTALL v2.0'
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
& $Procrun ("//DS//{0}" -f $SvcName)
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FATAL] Procrun uninstall failed. ExitCode=$LASTEXITCODE" -ForegroundColor Red
    exit 4102
}

# Verify removal best-effort
sc.exe query $SvcName > $null 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[WARN] Service still queryable after uninstall (SCM cache). Reboot may be required." -ForegroundColor Yellow
} else {
    Write-Host "[PASS] Service removed: $SvcName"
}

Write-Host ''
Write-Host '[SUCCESS] VMGuard Watcher uninstalled.'
exit 0
