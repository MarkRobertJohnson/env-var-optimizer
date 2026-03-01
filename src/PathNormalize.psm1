Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Split-PathVariableValue {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return @()
    }

    return @($Value -split ';')
}

function Join-PathVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$Entries
    )

    $clean = @(
        $Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
    )

    return ($clean -join ';')
}

function Remove-TrailingSeparatorSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -match '^[a-zA-Z]:\\$') {
        return $Path.ToLowerInvariant()
    }

    if ($Path -match '^\\\\[^\\]+\\[^\\]+\\?$') {
        return $Path.TrimEnd('\\')
    }

    return $Path.TrimEnd('\\')
}

function Normalize-PathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    $trimmed = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [pscustomobject]@{
            Original   = $Path
            Trimmed    = $trimmed
            Expanded   = ''
            Normalized = ''
            Canonical  = ''
            IsEmpty    = $true
        }
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($trimmed)
    $slashNormalized = $expanded -replace '/', '\\'
    $normalized = Remove-TrailingSeparatorSafe -Path $slashNormalized
    $canonical = $normalized.ToLowerInvariant()

    return [pscustomobject]@{
        Original   = $Path
        Trimmed    = $trimmed
        Expanded   = $expanded
        Normalized = $normalized
        Canonical  = $canonical
        IsEmpty    = $false
    }
}

function Get-CanonicalPathKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    return (Normalize-PathEntry -Path $Path).Canonical
}

function Get-DefaultCompressionVariables {
    [CmdletBinding()]
    param()

    return @{
        '%ProgramFiles%'       = $env:ProgramFiles
        '%ProgramFiles(x86)%'  = ${env:ProgramFiles(x86)}
        '%ProgramData%'        = $env:ProgramData
        '%USERPROFILE%'        = $env:USERPROFILE
        '%LOCALAPPDATA%'       = $env:LOCALAPPDATA
        '%APPDATA%'            = $env:APPDATA
        '%SystemRoot%'         = $env:SystemRoot
        '%WINDIR%'             = $env:WINDIR
    }
}

function ConvertTo-CompressedPathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [hashtable]$Variables = $(Get-DefaultCompressionVariables)
    )

    $best = $Path
    foreach ($name in ($Variables.Keys | Sort-Object)) {
        $value = $Variables[$name]
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        if ($Path.StartsWith($value, [System.StringComparison]::OrdinalIgnoreCase)) {
            $candidate = $name + $Path.Substring($value.Length)
            if ($candidate.Length -lt $best.Length) {
                $best = $candidate
            }
        }
    }

    return $best
}

Export-ModuleMember -Function Split-PathVariableValue, Join-PathVariableValue, Normalize-PathEntry, Get-CanonicalPathKey, ConvertTo-CompressedPathEntry, Get-DefaultCompressionVariables
