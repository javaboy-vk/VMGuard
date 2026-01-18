<#
================================================================================
 VMGuard – Simulate VM Running State – v1.1
================================================================================
 Script Name : vmguard-simulate-vm-running.ps1
 Author      : javaboy-vk
 Date        : 2026-01-09
 Version     : 1.1

 PURPOSE
   Deterministically simulate VM running state via flag file.

 v1.1 CHANGE
   - Hardened parameter binding with CmdletBinding().
   - Explicitly defined Mode as positional parameter 0.
   - Eliminates cases where "-Mode" is mis-bound as a value.
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet("on","off","status")]
    [string]$Mode = "status",

    [Parameter(Mandatory = $false)]
    [string]$VmName  = "AtlasW19",

    [Parameter(Mandatory = $false)]
    [string]$BaseDir = "P:\Scripts\VMGuard"
)

$FlagDir  = Join-Path $BaseDir "flags"
$FlagFile = Join-Path $FlagDir ("{0}_running.flag" -f $VmName)

New-Item -ItemType Directory -Force -Path $FlagDir | Out-Null

switch ($Mode) {
    "on" {
        Set-Content -Path $FlagFile -Value "VMGuard simulated running: $(Get-Date)" -Force
        Write-Host "SIMULATION: VM marked RUNNING."
    }
    "off" {
        if (Test-Path $FlagFile) { Remove-Item $FlagFile -Force }
        Write-Host "SIMULATION: VM marked NOT RUNNING."
    }
    "status" {
        if (Test-Path $FlagFile) { 
            Write-Host "STATUS: RUNNING" 
        } else { 
            Write-Host "STATUS: NOT RUNNING" 
        }
    }
}
