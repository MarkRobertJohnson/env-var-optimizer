Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ShimManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Shim manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($null -eq $manifest.shims) {
        throw 'Manifest must contain a shims array.'
    }

    return $manifest
}

function Resolve-ShimConflicts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Manifest
    )

    $priorityMap = @{}
    $priorityProperty = $Manifest.PSObject.Properties['priority']
    if ($null -ne $priorityProperty -and $null -ne $priorityProperty.Value) {
        foreach ($property in $priorityProperty.Value.PSObject.Properties) {
            $priorityMap[$property.Name.ToLowerInvariant()] = [string]$property.Value
        }
    }

    $resolved = @()
    $groups = @($Manifest.shims | Group-Object { ([string]$_.name).ToLowerInvariant() })

    foreach ($group in $groups) {
        if ($group.Count -eq 1) {
            $resolved += $group.Group[0]
            continue
        }

        $name = $group.Name
        if (-not $priorityMap.ContainsKey($name)) {
            throw "Duplicate shim name '$name' found. Add Manifest.priority.$name with preferred target."
        }

        $preferredTarget = $priorityMap[$name]
        $winner = $group.Group | Where-Object { ([string]$_.target).Equals($preferredTarget, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1

        if ($null -eq $winner) {
            throw "Priority target '$preferredTarget' for shim '$name' does not match any duplicate entries."
        }

        $resolved += $winner
    }

    return $resolved
}

function Get-CmdLauncherContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    if ($Target.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "@echo off`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Target`" %*`r`n"
    }

    return "@echo off`r`n`"$Target`" %*`r`n"
}

function Get-Ps1LauncherContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    return "& `"$Target`" @args`r`n"
}

function Sync-PathShims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [string]$BinDir = 'C:\\Tools\\bin',
        [switch]$WhatIf
    )

    $manifest = Read-ShimManifest -ManifestPath $ManifestPath
    $shims = Resolve-ShimConflicts -Manifest $manifest

    if (-not $WhatIf) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    }

    $results = @()
    foreach ($shim in $shims) {
        $name = [string]$shim.name
        $target = [string]$shim.target
        $launcherType = if ([string]::IsNullOrWhiteSpace([string]$shim.launcherType)) { 'cmd' } else { [string]$shim.launcherType }

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Shim name cannot be empty.'
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            throw "Shim '$name' is missing target."
        }

        $cmdPath = Join-Path $BinDir ($name + '.cmd')
        $cmdContent = Get-CmdLauncherContent -Target $target

        $cmdAction = 'updated'
        if (-not (Test-Path -LiteralPath $cmdPath -PathType Leaf)) {
            $cmdAction = 'created'
        }

        if (-not $WhatIf) {
            $cmdContent | Set-Content -Path $cmdPath -Encoding ASCII
        }

        $results += [pscustomobject]@{
            name       = $name
            launcher   = $cmdPath
            action     = $cmdAction
            target     = $target
            launcherType = 'cmd'
        }

        if ($launcherType -eq 'cmd+ps1') {
            $ps1Path = Join-Path $BinDir ($name + '.ps1')
            $ps1Content = Get-Ps1LauncherContent -Target $target
            $ps1Action = 'updated'
            if (-not (Test-Path -LiteralPath $ps1Path -PathType Leaf)) {
                $ps1Action = 'created'
            }

            if (-not $WhatIf) {
                $ps1Content | Set-Content -Path $ps1Path -Encoding ASCII
            }

            $results += [pscustomobject]@{
                name       = $name
                launcher   = $ps1Path
                action     = $ps1Action
                target     = $target
                launcherType = 'ps1'
            }
        }
    }

    $resolvedBinDir = $BinDir
    if (Test-Path -LiteralPath $BinDir -PathType Container) {
        $resolvedBinDir = (Resolve-Path -LiteralPath $BinDir).Path
    }

    return [pscustomobject]@{
        syncedAt      = (Get-Date).ToUniversalTime().ToString('o')
        manifestPath  = (Resolve-Path -LiteralPath $ManifestPath).Path
        binDir        = $resolvedBinDir
        shimCount     = $shims.Count
        launchers     = $results
    }
}

Export-ModuleMember -Function Sync-PathShims, Read-ShimManifest
