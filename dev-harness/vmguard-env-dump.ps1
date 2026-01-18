<#
================================================================================
 VMGuard – Environment Dump Utility – v1.0
================================================================================
 Script Name : vmguard-env-dump.ps1
 Author      : javaboy-vk
 Date        : 2026-01-17
 Version     : 1.0

 PURPOSE
   Produces a structured diagnostic dump of the VMGuard runtime environment,
   including configuration, directory layout, services, scheduled tasks,
   kernel object references, and OS context.

 RESPONSIBILITIES
   - Load vmguard.config.json
   - Resolve and validate VMGuard root
   - Capture environment and runtime state
   - Emit a single timestamped diagnostic file

 NON-RESPONSIBILITIES
   - Does NOT modify system state
   - Does NOT control services
   - Does NOT signal kernel events

 LIFECYCLE CONTEXT
   Developer harness / support utility. Safe to execute at any time.

================================================================================
#>

# ============================================================
# 1. Bootstrap
# ============================================================

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$VMGuardRoot = Resolve-Path "$ScriptRoot\.."
$ConfigPath  = Join-Path $VMGuardRoot "vmguard.config.json"
$OutDir      = Join-Path $VMGuardRoot "diagnostics"

if (!(Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutFile   = Join-Path $OutDir "vmguard-env-dump-$Timestamp.txt"

"===========================================" | Out-File $OutFile
" VMGuard Environment Dump v1.0"              | Out-File $OutFile -Append
" Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File $OutFile -Append
" Host : $env:COMPUTERNAME"                   | Out-File $OutFile -Append
" User : $env:USERNAME"                       | Out-File $OutFile -Append
" PID  : $PID"                                | Out-File $OutFile -Append
" Root : $VMGuardRoot"                        | Out-File $OutFile -Append
"===========================================" | Out-File $OutFile -Append
"" | Out-File $OutFile -Append

function Write-Section($title) {
    "" | Out-File $OutFile -Append
    "-------------------------------------------" | Out-File $OutFile -Append
    $title | Out-File $OutFile -Append
    "-------------------------------------------" | Out-File $OutFile -Append
}

# ============================================================
# 2. Configuration
# ============================================================

Write-Section "CONFIGURATION"

if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath | Out-File $OutFile -Append
} else {
    "[WARN] vmguard.config.json not found." | Out-File $OutFile -Append
}

# ============================================================
# 3. Directory Layout
# ============================================================

Write-Section "DIRECTORY STRUCTURE"
Get-ChildItem $VMGuardRoot -Recurse -Directory |
    Select-Object FullName |
    Out-File $OutFile -Append

# ============================================================
# 4. Services
# ============================================================

Write-Section "SERVICES (VMGuard*)"
Get-Service | Where-Object {$_.Name -like "*VMGuard*"} |
    Format-Table -AutoSize |
    Out-String |
    Out-File $OutFile -Append

# ============================================================
# 5. Scheduled Tasks
# ============================================================

Write-Section "SCHEDULED TASKS (VMGuard)"
schtasks /query /fo LIST | Select-String "VMGuard" |
    Out-String |
    Out-File $OutFile -Append

# ============================================================
# 6. OS + Runtime Context
# ============================================================

Write-Section "OS CONTEXT"
systeminfo | Out-String | Out-File $OutFile -Append

Write-Section "PROCESS CONTEXT"
Get-Process -Id $PID | Format-List * | Out-String | Out-File $OutFile -Append

# ============================================================
# 7. Completion
# ============================================================

"" | Out-File $OutFile -Append
"[END] Environment dump completed." | Out-File $OutFile -Append

Write-Host "==========================================="
Write-Host " VMGuard Environment Dump Completed"
Write-Host " Output: $OutFile"
Write-Host "==========================================="
