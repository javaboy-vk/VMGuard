<#
    Module: logging.ps1
    Author: javaboy-vk
    Date: 2026-01-04
    Version: 1.3
    Description:
      Unified logging to a single file and Windows Application Event Log.
#>

$Global:VMGuardBaseDir = "P:\Scripts\VMGuard"
$Global:VMGuardLogFile = "P:\Scripts\VMGuard\logs\vmguard.log"
$Global:VMGuardSource  = "VMGuard"

New-Item -ItemType Directory -Force -Path "P:\Scripts\VMGuard\logs" | Out-Null

try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($VMGuardSource)) {
        New-EventLog -LogName Application -Source $VMGuardSource
    }
} catch {}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("Information","Warning","Error")]
        [string]$Level = "Information"
    )

    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [$Level] $Message"

    try { Add-Content -Path $VMGuardLogFile -Value $line } catch {}

    try {
        $eventId = switch ($Level) {
            "Information" { 1000 }
            "Warning"     { 2000 }
            "Error"       { 3000 }
        }
        Write-EventLog -LogName Application -Source $VMGuardSource `
            -EntryType $Level -EventId $eventId -Message $Message
    } catch {}
}
