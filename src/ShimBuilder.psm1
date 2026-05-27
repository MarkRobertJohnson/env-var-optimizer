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

function Copy-ShimDefinitionProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Shim
    )

    $copied = [ordered]@{}
    foreach ($property in $Shim.PSObject.Properties) {
        $copied[$property.Name] = $property.Value
    }

    return $copied
}

function ConvertTo-ShimCommandSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [string]$ShimName
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        if ([string]::IsNullOrWhiteSpace($ShimName)) {
            throw 'Shim command cannot be empty.'
        }

        throw "Shim '$ShimName' has an empty command."
    }

    $parseErrors = $null
    $tokens = @([System.Management.Automation.PSParser]::Tokenize($Command, [ref]$parseErrors))
    if (@($parseErrors).Count -gt 0) {
        $firstError = @($parseErrors)[0]
        if ([string]::IsNullOrWhiteSpace($ShimName)) {
            throw "Invalid shim command '$Command'. $($firstError.Message)"
        }

        throw "Shim '$ShimName' has invalid command '$Command'. $($firstError.Message)"
    }

    $commandTokens = @()
    foreach ($token in $tokens) {
        $tokenType = [string]$token.Type
        if ($tokenType -in @('Command', 'CommandArgument', 'CommandParameter', 'String', 'Number')) {
            $commandTokens += [string]$token.Content
            continue
        }

        if ([string]::IsNullOrWhiteSpace($ShimName)) {
            throw "Shim command '$Command' uses unsupported PowerShell syntax near '$($token.Content)'."
        }

        throw "Shim '$ShimName' command uses unsupported PowerShell syntax near '$($token.Content)'."
    }

    if (@($commandTokens).Count -eq 0) {
        if ([string]::IsNullOrWhiteSpace($ShimName)) {
            throw "Shim command '$Command' did not produce an executable token."
        }

        throw "Shim '$ShimName' command did not produce an executable token."
    }

    $target = [string]$commandTokens[0]
    if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('-')) {
        if ([string]::IsNullOrWhiteSpace($ShimName)) {
            throw "Shim command '$Command' must start with an executable or script path."
        }

        throw "Shim '$ShimName' command must start with an executable or script path."
    }

    $fixedArguments = @()
    if (@($commandTokens).Count -gt 1) {
        $fixedArguments = @($commandTokens[1..(@($commandTokens).Count - 1)])
    }

    return [pscustomobject]@{
        target         = $target
        fixedArguments = $fixedArguments
    }
}

function New-ResolvedShimDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Shim,
        [string]$Name,
        [string]$Target,
        [string[]]$FixedArguments,
        [string]$SourceKey
    )

    $resolved = Copy-ShimDefinitionProperties -Shim $Shim

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $resolved['name'] = $Name
    }

    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        $resolved['target'] = $Target
    }

    $resolved['fixedArguments'] = @($FixedArguments | Where-Object { $null -ne $_ })
    $resolved['sourceKey'] = $SourceKey

    return [pscustomobject]$resolved
}

function Resolve-ShimTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        [Parameter(Mandatory)]
        [string]$BasePath
    )

    if ([System.IO.Path]::IsPathRooted($Target)) {
        return [System.IO.Path]::GetFullPath($Target)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Target))
}

function Get-ShimSourceKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Shim
    )

    $sourceKeyProperty = $Shim.PSObject.Properties['sourceKey']
    if ($null -ne $sourceKeyProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceKeyProperty.Value)) {
        return [string]$sourceKeyProperty.Value
    }

    $commandProperty = $Shim.PSObject.Properties['command']
    if ($null -ne $commandProperty -and -not [string]::IsNullOrWhiteSpace([string]$commandProperty.Value)) {
        return [string]$commandProperty.Value
    }

    $targetProperty = $Shim.PSObject.Properties['target']
    if ($null -ne $targetProperty -and -not [string]::IsNullOrWhiteSpace([string]$targetProperty.Value)) {
        return [string]$targetProperty.Value
    }

    return $null
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
        $targetProperty = $shim.PSObject.Properties['target']
        $commandProperty = $shim.PSObject.Properties['command']
        $target = if ($null -ne $targetProperty -and $null -ne $targetProperty.Value) { [string]$targetProperty.Value } else { $null }
        $command = if ($null -ne $commandProperty -and $null -ne $commandProperty.Value) { [string]$commandProperty.Value } else { $null }

        if (-not [string]::IsNullOrWhiteSpace($target) -and -not [string]::IsNullOrWhiteSpace($command)) {
            $shimLabel = if ([string]::IsNullOrWhiteSpace($declaredName)) { 'Unnamed shim' } else { "Shim '$declaredName'" }
            throw "$shimLabel must define exactly one of target or command."
        }

        if (-not [string]::IsNullOrWhiteSpace($command)) {
            if ([string]::IsNullOrWhiteSpace($declaredName)) {
                throw "Shim command '$command' requires an explicit name."
            }

            $commandSpec = ConvertTo-ShimCommandSpec -Command $command -ShimName $declaredName
            $expandedShims += New-ResolvedShimDefinition -Shim $shim -Name $declaredName -Target ([string]$commandSpec.target) -FixedArguments @($commandSpec.fixedArguments) -SourceKey $command
            continue
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            $expandedShims += $shim
            continue
        }

        if (-not [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($target)) {
            $resolvedTarget = Resolve-ShimTargetPath -Target $target -BasePath $manifestDir

            if ([string]::IsNullOrWhiteSpace($declaredName)) {
                $inferredName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedTarget)
                if ([string]::IsNullOrWhiteSpace($inferredName)) {
                    throw "Shim target '$target' requires an explicit name because a name could not be inferred from the path."
                }

                $expandedShims += New-ResolvedShimDefinition -Shim $shim -Name $inferredName -Target $resolvedTarget -FixedArguments @() -SourceKey $resolvedTarget
                continue
            }

            $expandedShims += New-ResolvedShimDefinition -Shim $shim -Name $declaredName -Target $resolvedTarget -FixedArguments @() -SourceKey $resolvedTarget
            continue
        }

        $targetPattern = Resolve-ShimTargetPath -Target $target -BasePath $manifestDir

        $matches = @(Get-ChildItem -Path $targetPattern -File -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
        if ($matches.Count -eq 0) {
            throw "Shim wildcard target '$target' did not match any files."
        }

        if (-not [string]::IsNullOrWhiteSpace($declaredName) -and $matches.Count -gt 1) {
            throw "Shim name '$declaredName' cannot be used with wildcard target '$target' because it matched multiple files. Omit name to auto-generate shim names."
        }

        foreach ($match in $matches) {
            $expandedName = if ([string]::IsNullOrWhiteSpace($declaredName)) { [System.IO.Path]::GetFileNameWithoutExtension($match.Name) } else { $declaredName }
            $expandedShims += New-ResolvedShimDefinition -Shim $shim -Name $expandedName -Target $match.FullName -FixedArguments @() -SourceKey $match.FullName
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
            throw "Duplicate shim name '$name' found. Add Manifest.priority.$name with the preferred target or command."
        }

        $preferredSourceKey = $priorityMap[$name]
        $winner = $group.Group | Where-Object {
            $sourceKey = Get-ShimSourceKey -Shim $_
            (-not [string]::IsNullOrWhiteSpace($sourceKey)) -and $sourceKey.Equals($preferredSourceKey, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if ($null -eq $winner) {
            throw "Priority value '$preferredSourceKey' for shim '$name' does not match any duplicate entries."
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
        [psobject]$ArgumentPolicy,
        [string[]]$FixedArguments = @()
    )

    $normalizedFixedArguments = @($FixedArguments | Where-Object { $null -ne $_ })

    $policyJson = [pscustomobject]@{
        lockedPositional = @($ArgumentPolicy.lockedPositional)
        defaults         = [pscustomobject]$ArgumentPolicy.defaults
        lockedOptions    = [pscustomobject]$ArgumentPolicy.lockedOptions
        fixedArguments   = $normalizedFixedArguments
        allowPositionalTail = [bool]$ArgumentPolicy.allowPositionalTail
    } | ConvertTo-Json -Compress -Depth 8
    $escapedPolicyJson = $policyJson.Replace("'", "''")

    return @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

`$policy = '$escapedPolicyJson' | ConvertFrom-Json
`$userArgs = @(`$args)

function Test-ShimDebugEnabled {
    [CmdletBinding()]
    param(
        [string]`$Value
    )

    if ([string]::IsNullOrWhiteSpace(`$Value)) {
        return `$false
    }

    switch (`$Value.Trim().ToLowerInvariant()) {
        '0' { return `$false }
        'false' { return `$false }
        'no' { return `$false }
        'off' { return `$false }
        default { return `$true }
    }
}

function ConvertTo-ShimDebugJson {
    [CmdletBinding()]
    param(
        `$Value
    )

    return (`$Value | ConvertTo-Json -Compress -Depth 8)
}

`$script:shimDebugEnabled = Test-ShimDebugEnabled -Value ([Environment]::GetEnvironmentVariable('PATHOPT_SHIM_DEBUG'))

function Write-ShimDebugMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]`$Message
    )

    if (`$script:shimDebugEnabled) {
        Write-Host "[pathopt shim debug] `$Message"
    }
}

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
`$finalArgs += @(`$policy.fixedArguments)
`$finalArgs += `$lockedOptionPairs
`$finalArgs += `$userArgs
`$finalArgs += `$defaultPairs

Write-ShimDebugMessage "shim=`$PSCommandPath"
Write-ShimDebugMessage "cwd=`$((Get-Location).Path)"
Write-ShimDebugMessage "target=$Target"
Write-ShimDebugMessage "policy=`$(ConvertTo-ShimDebugJson -Value `$policy)"
Write-ShimDebugMessage "userArgs=`$(ConvertTo-ShimDebugJson -Value `$userArgs)"
Write-ShimDebugMessage "finalArgs=`$(ConvertTo-ShimDebugJson -Value `$finalArgs)"

try {
    & "$Target" @finalArgs
    `$lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    if (`$null -ne `$lastExitCodeVariable) {
        Write-ShimDebugMessage "exitCode=`$([int]`$lastExitCodeVariable.Value)"
        exit [int]`$lastExitCodeVariable.Value
    }
}
catch {
    Write-ShimDebugMessage "exception=`$(`$_.Exception.Message)"
    throw
}

Write-ShimDebugMessage 'exitCode=0'
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
        $targetProperty = $shim.PSObject.Properties['target']
        $commandProperty = $shim.PSObject.Properties['command']
        $fixedArgumentsProperty = $shim.PSObject.Properties['fixedArguments']
        $target = if ($null -ne $targetProperty -and $null -ne $targetProperty.Value) { [string]$targetProperty.Value } else { $null }
        $isCommandShim = ($null -ne $commandProperty -and -not [string]::IsNullOrWhiteSpace([string]$commandProperty.Value))
        $fixedArguments = if ($null -ne $fixedArgumentsProperty -and $null -ne $fixedArgumentsProperty.Value) { @($fixedArgumentsProperty.Value | ForEach-Object { [string]$_ }) } else { @() }
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

        if ($isCommandShim -and $launcherType -eq 'cmd') {
            throw "Shim '$name' uses command and must set launcherType to 'ps1' or 'cmd+ps1'."
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
            $ps1Content = Get-Ps1LauncherContent -Target $target -ArgumentPolicy $argumentPolicy -FixedArguments $fixedArguments
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
