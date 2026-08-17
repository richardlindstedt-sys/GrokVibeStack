<#
.SYNOPSIS
    Gate schema version shared by AI pass-cache and reports.
.NOTES
    Bump GATE_SCHEMA_VERSION whenever reviewer briefs, profiles, cache key
    fields, or pass/fail semantics change. Old cache entries without this
    version (or with a different one) are a miss — fail closed.
#>

if (-not $script:GATE_SCHEMA_VERSION) {
    $script:GATE_SCHEMA_VERSION = 3
}

function Get-GateSchemaVersion {
    return [int]$script:GATE_SCHEMA_VERSION
}
