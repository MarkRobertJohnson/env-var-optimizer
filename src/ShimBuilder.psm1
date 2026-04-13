Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ShimArgumentPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Shim
    )

    $policy = [ordered]@{
        lockedPositional = @()
        defaults         = [ordered]@{}
        lockedOptions    = [ordered]@{}
        allowPositionalTail = $false
    }

    $argsProperty = $Shim.PSObject.Properties['args']
    if ($null -eq $argsProperty -or $null -eq $argsProperty.Value) {
        return [pscustomobject]$policy
    }

    $argsObject = $argsProperty.Value

    $lockedPositionalProperty = $argsObject.PSObject.Properties['lockedPositional']
    if ($null -ne $lockedPositionalProperty -and $null -ne $lockedPositionalProperty.Value) {
        foreach ($token in @($lockedPositionalProperty.Value)) {
            $tokenText = [string]$token
            if ([string]::IsNullOrWhiteSpace($tokenText)) {
                throw "Shim '$($Shim.name)' has an empty args.lockedPositional value."
            }

            if ($tokenText.StartsWith('-')) {
                throw "Shim '$($Shim.name)' has invalid args.lockedPositional token '$tokenText'. Use positional tokens only."
            }

            $policy.lockedPositional += $tokenText
        }
    }

    $defaultProperty = $argsObject.PSObject.Properties['defaults']
    if ($null -ne $defaultProperty -and $null -ne $defaultProperty.Value) {
        foreach ($entry in $defaultProperty.Value.PSObject.Properties) {
            $optionName = [string]$entry.Name
            if ([string]::IsNullOrWhiteSpace($optionName) -or -not $optionName.StartsWith('--')) {
                throw "Shim '$($Shim.name)' has invalid args.defaults option '$optionName'. Long options must start with '--'."
            }

            $defaultValue = $entry.Value
            $isSwitchDefault = $defaultValue -is [bool]
            if (-not $isSwitchDefault -and [string]::IsNullOrWhiteSpace([string]$defaultValue)) {
                throw "Shim '$($Shim.name)' has empty default value for option '$optionName'."
            }

            $policy.defaults[$optionName] = $defaultValue
        }
    }

    $lockedOptionsProperty = $argsObject.PSObject.Properties['lockedOptions']
    if ($null -ne $lockedOptionsProperty -and $null -ne $lockedOptionsProperty.Value) {
        foreach ($entry in $lockedOptionsProperty.Value.PSObject.Properties) {
            $optionName = [string]$entry.Name
            if ([string]::IsNullOrWhiteSpace($optionName) -or -not $optionName.StartsWith('--')) {
                throw "Shim '$($Shim.name)' has invalid args.lockedOptions option '$optionName'. Long options must start with '--'."
            }

            $lockedValue = $entry.Value
            $isSwitchDefault = $lockedValue -is [bool]
            if (-not $isSwitchDefault -and [string]::IsNullOrWhiteSpace([string]$lockedValue)) {
                throw "Shim '$($Shim.name)' has empty locked value for option '$optionName'."
            }

            $policy.lockedOptions[$optionName] = $lockedValue
        }
    }

    foreach ($optionName in @($policy.defaults.Keys)) {
        if ($policy.lockedOptions.Contains($optionName)) {
            throw "Shim '$($Shim.name)' defines '$optionName' in both args.defaults and args.lockedOptions."
        }
    }

    $allowPositionalTailProperty = $argsObject.PSObject.Properties['allowPositionalTail']
    if ($null -ne $allowPositionalTailProperty -and $null -ne $allowPositionalTailProperty.Value) {
        $policy.allowPositionalTail = [bool]$allowPositionalTailProperty.Value
    }

    return [pscustomobject]$policy
}

function Test-HasShimArgumentPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Policy
    )

    return (@($Policy.lockedPositional).Count -gt 0) -or (@($Policy.defaults.Keys).Count -gt 0) -or (@($Policy.lockedOptions.Keys).Count -gt 0) -or [bool]$Policy.allowPositionalTail
}

function Get-FileWriteAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Content
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'created'
    }

    $current = [System.IO.File]::ReadAllText($Path)
    if ($current -ceq $Content) {
        return 'unchanged'
    }

    return 'updated'
}

function Read-ShimInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return $null
    }

    return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
}

function Write-ShimInstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [string]$BinDir,
        [Parameter(Mandatory)]
        [string[]]$ManagedLaunchers
    )

    $stateDir = Split-Path -Parent $StatePath
    if (-not [string]::IsNullOrWhiteSpace($stateDir)) {
        New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    }

    $state = [pscustomobject]@{
        version          = 1
        updatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        manifestPath     = $ManifestPath
        binDir           = $BinDir
        managedLaunchers = @($ManagedLaunchers)
    }

    $state | ConvertTo-Json -Depth 8 | Set-Content -Path $StatePath -Encoding UTF8
}

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

    $manifestDir = Split-Path -Parent $ManifestPath
    $expandedShims = @()

    foreach ($shim in @($manifest.shims)) {
        $declaredNameProperty = $shim.PSObject.Properties['name']
        $declaredName = if ($null -ne $declaredNameProperty) { [string]$declaredNameProperty.Value } else { $null }
        $target = [string]$shim.target
        if ([string]::IsNullOrWhiteSpace($target)) {
            $expandedShims += $shim
            continue
        }

        if (-not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($target)) {
            if ([string]::IsNullOrWhiteSpace($declaredName)) {
                $resolvedTarget = if ([System.IO.Path]::IsPathRooted($target)) {
                    $target
                }
                else {
                    Join-Path $manifestDir $target
                }

                $inferredName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedTarget)
                if ([string]::IsNullOrWhiteSpace($inferredName)) {
                    throw "Shim target '$target' requires an explicit name because a name could not be inferred from the path."
                }

                $expandedShim = [ordered]@{}
                foreach ($property in $shim.PSObject.Properties) {
                    $expandedShim[$property.Name] = $property.Value
                }

                $expandedShim['name'] = $inferredName
                $expandedShims += [pscustomobject]$expandedShim
                continue
            }

            $expandedShims += $shim
            continue
        }

        $targetPattern = if ([System.IO.Path]::IsPathRooted($target)) {
            $target
        }
        else {
            Join-Path $manifestDir $target
        }

        $matches = @(Get-ChildItem -Path $targetPattern -File -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
        if ($matches.Count -eq 0) {
            throw "Shim wildcard target '$target' did not match any files."
        }

        if (-not [string]::IsNullOrWhiteSpace($declaredName) -and $matches.Count -gt 1) {
            throw "Shim name '$declaredName' cannot be used with wildcard target '$target' because it matched multiple files. Omit name to auto-generate shim names."
        }

        foreach ($match in $matches) {
            $expandedShim = [ordered]@{}
            foreach ($property in $shim.PSObject.Properties) {
                $expandedShim[$property.Name] = $property.Value
            }

            if ([string]::IsNullOrWhiteSpace($declaredName)) {
                $expandedShim['name'] = [System.IO.Path]::GetFileNameWithoutExtension($match.Name)
            }

            $expandedShim['target'] = $match.FullName
            $expandedShims += [pscustomobject]$expandedShim
        }
    }

    $manifest.shims = @($expandedShims)

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
        [string]$Target,
        [string]$Ps1LauncherPath
    )

    if (-not [string]::IsNullOrWhiteSpace($Ps1LauncherPath)) {
        return "@echo off`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Ps1LauncherPath`" %*`r`n"
    }

    if ($Target.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        return "@echo off`r`npwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Target`" %*`r`n"
    }

    return "@echo off`r`n`"$Target`" %*`r`n"
}

function Get-Ps1LauncherContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        [Parameter(Mandatory)]
        [psobject]$ArgumentPolicy
    )

    $policyJson = [pscustomobject]@{
        lockedPositional = @($ArgumentPolicy.lockedPositional)
        defaults         = [pscustomobject]$ArgumentPolicy.defaults
        lockedOptions    = [pscustomobject]$ArgumentPolicy.lockedOptions
        allowPositionalTail = [bool]$ArgumentPolicy.allowPositionalTail
    } | ConvertTo-Json -Compress -Depth 8
    $escapedPolicyJson = $policyJson.Replace("'", "''")

    return @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

`$policy = '$escapedPolicyJson' | ConvertFrom-Json
`$userArgs = @(`$args)

function Get-UserOptionMap {
    [CmdletBinding()]
    param(
        [string[]]`$Args
    )

    `$map = @{}

    for (`$i = 0; `$i -lt `$Args.Count; `$i++) {
        `$token = [string]`$Args[`$i]
        if (-not `$token.StartsWith('--')) {
            continue
        }

        `$lowerToken = `$token.ToLowerInvariant()
        if (`$token.Contains('=')) {
            `$eqIndex = `$token.IndexOf('=')
            `$optionName = `$token.Substring(0, `$eqIndex)
            `$optionValue = `$token.Substring(`$eqIndex + 1)
            `$map[`$optionName.ToLowerInvariant()] = `$optionValue
            continue
        }

        if ((`$i + 1) -lt `$Args.Count -and -not ([string]`$Args[`$i + 1]).StartsWith('-')) {
            `$map[`$lowerToken] = [string]`$Args[`$i + 1]
            `$i++
            continue
        }

        `$map[`$lowerToken] = `$true
    }

    return `$map
}

if (@(`$policy.lockedPositional).Count -gt 0 -and -not [bool]`$policy.allowPositionalTail) {
    `$lockedTokenList = @(`$policy.lockedPositional) -join ', '
    foreach (`$token in `$userArgs) {
        if (-not ([string]`$token).StartsWith('-')) {
            throw "This shim locks positional command tokens (`$lockedTokenList). Positional overrides are not allowed."
        }
    }
}

`$userOptionMap = Get-UserOptionMap -Args `$userArgs
`$lockedOptionPairs = @()

if (`$null -ne `$policy.lockedOptions) {
    foreach (`$property in @(`$policy.lockedOptions.PSObject.Properties)) {
        `$optionName = [string]`$property.Name
        `$optionLower = `$optionName.ToLowerInvariant()
        `$lockedValue = `$property.Value

        if (`$userOptionMap.ContainsKey(`$optionLower)) {
            `$userValue = `$userOptionMap[`$optionLower]
            `$isDifferent = `$false

            if (`$lockedValue -is [bool] -and `$userValue -is [bool]) {
                `$isDifferent = (`$lockedValue -ne `$userValue)
            }
            else {
                `$isDifferent = (-not ([string]`$lockedValue).Equals([string]`$userValue, [System.StringComparison]::OrdinalIgnoreCase))
            }

            if (`$isDifferent) {
                throw "Option `$optionName is locked by this shim and cannot be overridden."
            }
        }
        else {
            `$lockedOptionPairs += `$optionName
            if (-not (`$lockedValue -is [bool])) {
                `$lockedOptionPairs += [string]`$lockedValue
            }
        }
    }
}

`$defaultPairs = @()
if (`$null -ne `$policy.defaults) {
    foreach (`$property in @(`$policy.defaults.PSObject.Properties)) {
        `$optionName = [string]`$property.Name
        `$optionLower = `$optionName.ToLowerInvariant()

        if (`$userOptionMap.ContainsKey(`$optionLower)) {
            continue
        }

        `$defaultValue = `$property.Value
        if (`$defaultValue -is [bool]) {
            if (`$defaultValue) {
                `$defaultPairs += `$optionName
            }

            continue
        }

        `$defaultPairs += `$optionName
        `$defaultPairs += [string]`$defaultValue
    }
}

`$finalArgs = @()
`$finalArgs += @(`$policy.lockedPositional)
`$finalArgs += `$lockedOptionPairs
`$finalArgs += `$userArgs
`$finalArgs += `$defaultPairs

& "$Target" @finalArgs
`$lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
if (`$null -ne `$lastExitCodeVariable) {
    exit [int]`$lastExitCodeVariable.Value
}

exit 0
"@
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
        $argumentPolicy = ConvertTo-ShimArgumentPolicy -Shim $shim
        $hasArgumentPolicy = Test-HasShimArgumentPolicy -Policy $argumentPolicy

        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Shim name cannot be empty.'
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            throw "Shim '$name' is missing target."
        }

        if ($launcherType -notin @('cmd', 'cmd+ps1', 'ps1')) {
            throw "Shim '$name' has unsupported launcherType '$launcherType'. Use 'cmd', 'ps1', or 'cmd+ps1'."
        }

        if ($hasArgumentPolicy -and $launcherType -eq 'cmd') {
            throw "Shim '$name' uses args policy and must set launcherType to 'ps1' or 'cmd+ps1'."
        }

        $cmdPath = Join-Path $BinDir ($name + '.cmd')
        $ps1Path = Join-Path $BinDir ($name + '.ps1')

        if ($launcherType -in @('cmd', 'cmd+ps1')) {
            $cmdPs1Path = if ($launcherType -eq 'cmd+ps1') { $ps1Path } else { $null }
            $cmdContent = Get-CmdLauncherContent -Target $target -Ps1LauncherPath $cmdPs1Path

            $cmdAction = Get-FileWriteAction -Path $cmdPath -Content $cmdContent

            if (-not $WhatIf -and $cmdAction -ne 'unchanged') {
                $cmdContent | Set-Content -Path $cmdPath -Encoding ASCII -NoNewline
            }

            $results += [pscustomobject]@{
                name         = $name
                launcher     = $cmdPath
                action       = $cmdAction
                target       = $target
                launcherType = 'cmd'
            }
        }

        if ($launcherType -in @('ps1', 'cmd+ps1')) {
            $ps1Content = Get-Ps1LauncherContent -Target $target -ArgumentPolicy $argumentPolicy
            $ps1Action = Get-FileWriteAction -Path $ps1Path -Content $ps1Content

            if (-not $WhatIf -and $ps1Action -ne 'unchanged') {
                $ps1Content | Set-Content -Path $ps1Path -Encoding ASCII -NoNewline
            }

            $results += [pscustomobject]@{
                name         = $name
                launcher     = $ps1Path
                action       = $ps1Action
                target       = $target
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

function Install-PathShims {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [string]$BinDir = 'C:\\Tools\\bin',
        [string]$StatePath,
        [switch]$WhatIf
    )

    $syncResult = Sync-PathShims -ManifestPath $ManifestPath -BinDir $BinDir -WhatIf:$WhatIf

    $effectiveStatePath = $StatePath
    if ([string]::IsNullOrWhiteSpace($effectiveStatePath)) {
        $effectiveStatePath = Join-Path (Get-Location) '.pathopt\\state\\shim-install-state.json'
    }

    $previousState = Read-ShimInstallState -StatePath $effectiveStatePath
    $previousManagedLaunchers = @()
    if ($null -ne $previousState -and $null -ne $previousState.managedLaunchers) {
        $previousManagedLaunchers = @($previousState.managedLaunchers)
    }

    $desiredLaunchers = @($syncResult.launchers | Select-Object -ExpandProperty launcher)
    $desiredLaunchersMap = @{}
    foreach ($launcher in $desiredLaunchers) {
        $desiredLaunchersMap[[string]$launcher] = $true
    }

    $removedLaunchers = @()
    foreach ($launcherPath in $previousManagedLaunchers) {
        if ($desiredLaunchersMap.ContainsKey([string]$launcherPath)) {
            continue
        }

        $action = if (Test-Path -LiteralPath $launcherPath -PathType Leaf) { 'removed' } else { 'already-missing' }
        if (-not $WhatIf -and $action -eq 'removed') {
            Remove-Item -LiteralPath $launcherPath -Force
        }

        $removedLaunchers += [pscustomobject]@{
            launcher = [string]$launcherPath
            action   = $action
        }
    }

    if (-not $WhatIf) {
        Write-ShimInstallState -StatePath $effectiveStatePath -ManifestPath $syncResult.manifestPath -BinDir $syncResult.binDir -ManagedLaunchers $desiredLaunchers
    }

    return [pscustomobject]@{
        syncedAt        = $syncResult.syncedAt
        manifestPath    = $syncResult.manifestPath
        binDir          = $syncResult.binDir
        shimCount       = $syncResult.shimCount
        launchers       = $syncResult.launchers
        removedLaunchers = $removedLaunchers
        statePath       = $effectiveStatePath
    }
}

Export-ModuleMember -Function Sync-PathShims, Read-ShimManifest, Install-PathShims
