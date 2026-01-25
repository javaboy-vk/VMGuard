<#
================================================================================
 VMGuard – Preshutdown Sentinel – Settings Reader – v1.1
================================================================================
 File        : read-sentinel-settings.ps1
 Author      : VMGuard Systems Engineer
 Date        : 2026-01-24
 Version     : 1.1

 PURPOSE
   Read VMGuard settings.json and emit sentinel-related values in a CMD-friendly
   KEY=VALUE format for downstream .cmd installers.

   IMPORTANT: STDOUT CONTRACT
     This script must remain parse-safe for .cmd callers.
     It must emit ONLY the following lines to STDOUT (in this order):
       SVC=...
       DISPLAY_NAME=...
       DESCRIPTION=...
       SENTINEL_REL=...

 RESPONSIBILITIES
   - Best-effort JSON load (never fail the caller)
   - Resolve sentinel identity fields from settings.json
   - Emit deterministic KEY=VALUE lines

 NON-RESPONSIBILITIES
   - Does NOT install services
   - Does NOT signal STOP
   - Does NOT assume absolute paths

================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SettingsJson
)

# ============================================================
# 1. Canonical Defaults (Fetched from settings.json)
# ============================================================
# Canonical values are sourced from configuration.
$svc         = $null
$displayName = $null
$description = $null
$sentinelRel = $null

# Last-resort baseline (only if settings.json is missing/unreadable/incomplete)
# NOTE: This preserves deterministic non-empty output for .cmd consumers.
$__baselineSvc         = 'VMGuard-Preshutdown-Sentinel'
$__baselineDisplayName = 'VMGuard Preshutdown Sentinel Service'
$__baselineDescription = 'VMGuard preshutdown-tier sentinel that signals Guard STOP event early during host shutdown.'
$__baselineSentinelRel = 'preshutdown_sentinel'

# ============================================================
# 2. Best-Effort JSON Load
# ============================================================

try {
    if (Test-Path -LiteralPath $SettingsJson) {
        $c = Get-Content -Raw -LiteralPath $SettingsJson | ConvertFrom-Json

        # Canonical schema:
        #   services.sentinel.(name|displayName|description)
        #   paths.sentinel
        if ($c.services.sentinel.name)        { $svc         = ([string]$c.services.sentinel.name).Trim() }
        if ($c.services.sentinel.displayName) { $displayName = ([string]$c.services.sentinel.displayName).Trim() }
        if ($c.services.sentinel.description) { $description = ([string]$c.services.sentinel.description).Trim() }
        if ($c.paths.sentinel)                { $sentinelRel = ([string]$c.paths.sentinel).Trim() }
    }
}
catch {
    # Best-effort: keep nulls and fall back to baseline below
}

# ============================================================
# 3. Baseline Fill (Only if missing from configuration)
# ============================================================

if (-not $svc)         { $svc         = $__baselineSvc }
if (-not $displayName) { $displayName = $__baselineDisplayName }
if (-not $description) { $description = $__baselineDescription }
if (-not $sentinelRel) { $sentinelRel = $__baselineSentinelRel }

# ============================================================
# 4. Deterministic Emission (STDOUT Contract)
# ============================================================

Write-Output "SVC=$svc"
Write-Output "DISPLAY_NAME=$displayName"
Write-Output "DESCRIPTION=$description"
Write-Output "SENTINEL_REL=$sentinelRel"
