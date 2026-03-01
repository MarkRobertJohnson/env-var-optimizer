Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -DisableNameChecking

function Get-ScopeEnvironmentMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine', 'Process')]
        [string]$Scope
    )

    $result = @{}
    $variables = [Environment]::GetEnvironmentVariables($Scope)
    foreach ($entry in $variables.GetEnumerator()) {
        $key = [string]$entry.Key
        $value = [string]$entry.Value
        $result[$key] = $value
    }

    return $result
}

function Get-EffectiveEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [hashtable]$UserVariables,
        [Parameter(Mandatory)]
        [hashtable]$MachineVariables
    )

    if ($UserVariables.ContainsKey($Name)) {
        return [pscustomobject]@{
            found  = $true
            source = 'User'
            value  = [string]$UserVariables[$Name]
        }
    }

    if ($MachineVariables.ContainsKey($Name)) {
        return [pscustomobject]@{
            found  = $true
            source = 'Machine'
            value  = [string]$MachineVariables[$Name]
        }
    }

    return [pscustomobject]@{
        found  = $false
        source = $null
        value  = $null
    }
}

function Merge-PathFromScopes {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$MachinePath,
        [AllowEmptyString()]
        [string]$UserPath
    )

    $machineEntries = @(Split-PathVariableValue -Value $MachinePath)
    $userEntries = @(Split-PathVariableValue -Value $UserPath)
    $inputEntries = @($machineEntries + $userEntries)

    $seen = @{}
    $kept = @()
    $duplicatesRemoved = 0

    foreach ($entry in $inputEntries) {
        $normalized = Normalize-PathEntry -Path $entry
        if ($normalized.IsEmpty) {
            continue
        }

        $key = $normalized.Canonical
        if ($seen.ContainsKey($key)) {
            $duplicatesRemoved++
            continue
        }

        $seen[$key] = $true
        $kept += $normalized.Trimmed
    }

    return [pscustomobject]@{
        entries           = $kept
        value             = (Join-PathVariableValue -Entries $kept)
        duplicatesRemoved = $duplicatesRemoved
        machineEntryCount = @($machineEntries).Count
        userEntryCount    = @($userEntries).Count
    }
}

function Invoke-PathRefresh {
    [CmdletBinding()]
    param(
        [switch]$WhatIf,
        [AllowEmptyString()]
        [string]$UserPathValue,
        [AllowEmptyString()]
        [string]$MachinePathValue
    )

    $currentProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
    if ($null -eq $currentProcessPath) {
        $currentProcessPath = ''
    }

    if ($PSBoundParameters.ContainsKey('UserPathValue') -and $null -ne $UserPathValue) {
        $userPath = $UserPathValue
    }
    else {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    if ($PSBoundParameters.ContainsKey('MachinePathValue') -and $null -ne $MachinePathValue) {
        $machinePath = $MachinePathValue
    }
    else {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    }

    if ($null -eq $userPath) { $userPath = '' }
    if ($null -eq $machinePath) { $machinePath = '' }

    if ([string]::IsNullOrWhiteSpace($userPath) -and [string]::IsNullOrWhiteSpace($machinePath) -and -not [string]::IsNullOrWhiteSpace($currentProcessPath)) {
        return [pscustomobject]@{
            variable          = 'Path'
            whatIf            = [bool]$WhatIf
            changed           = $false
            skipped           = $true
            reason            = 'empty_source_path'
            source            = 'Machine+User'
            beforeLength      = $currentProcessPath.Length
            afterLength       = $currentProcessPath.Length
            beforeEntryCount  = @(Split-PathVariableValue -Value $currentProcessPath).Count
            afterEntryCount   = @(Split-PathVariableValue -Value $currentProcessPath).Count
            duplicatesRemoved = 0
            machineEntryCount = 0
            userEntryCount    = 0
            value             = $currentProcessPath
        }
    }

    $merged = Merge-PathFromScopes -MachinePath $machinePath -UserPath $userPath
    $changed = $currentProcessPath -ne $merged.value

    if (-not $WhatIf -and $changed) {
        [Environment]::SetEnvironmentVariable('Path', $merged.value, 'Process')
    }

    return [pscustomobject]@{
        variable          = 'Path'
        whatIf            = [bool]$WhatIf
        changed           = $changed
        source            = 'Machine+User'
        beforeLength      = $currentProcessPath.Length
        afterLength       = $merged.value.Length
        beforeEntryCount  = @(Split-PathVariableValue -Value $currentProcessPath).Count
        afterEntryCount   = $merged.entries.Count
        duplicatesRemoved = $merged.duplicatesRemoved
        machineEntryCount = $merged.machineEntryCount
        userEntryCount    = $merged.userEntryCount
        value             = $merged.value
    }
}

function Invoke-EnvironmentRefresh {
    [CmdletBinding()]
    param(
        [string]$Scope = 'path',
        [switch]$WhatIf,
        [hashtable]$UserVariables,
        [hashtable]$MachineVariables,
        [AllowEmptyString()]
        [string]$UserPathValue,
        [AllowEmptyString()]
        [string]$MachinePathValue
    )

    $scopeValue = if ([string]::IsNullOrWhiteSpace($Scope)) { 'path' } else { $Scope }

    if ($PSBoundParameters.ContainsKey('UserVariables')) {
        $userVars = $UserVariables
    }
    else {
        $userVars = Get-ScopeEnvironmentMap -Scope User
    }

    if ($PSBoundParameters.ContainsKey('MachineVariables')) {
        $machineVars = $MachineVariables
    }
    else {
        $machineVars = Get-ScopeEnvironmentMap -Scope Machine
    }

    $operations = @()
    $changedCount = 0
    $skippedCount = 0

    if ($scopeValue.Equals('path', [System.StringComparison]::OrdinalIgnoreCase)) {
        $pathArgs = @{ WhatIf = [bool]$WhatIf }
        if ($PSBoundParameters.ContainsKey('UserPathValue')) { $pathArgs['UserPathValue'] = $UserPathValue }
        if ($PSBoundParameters.ContainsKey('MachinePathValue')) { $pathArgs['MachinePathValue'] = $MachinePathValue }

        $pathResult = Invoke-PathRefresh @pathArgs
        $operations += $pathResult
        if ($pathResult.changed) { $changedCount++ }
    }
    elseif ($scopeValue.Equals('all', [System.StringComparison]::OrdinalIgnoreCase)) {
        $pathArgs = @{ WhatIf = [bool]$WhatIf }
        if ($PSBoundParameters.ContainsKey('UserPathValue')) { $pathArgs['UserPathValue'] = $UserPathValue }
        if ($PSBoundParameters.ContainsKey('MachinePathValue')) { $pathArgs['MachinePathValue'] = $MachinePathValue }

        $pathResult = Invoke-PathRefresh @pathArgs
        $operations += $pathResult
        if ($pathResult.changed) { $changedCount++ }

        $names = @{}
        foreach ($name in $machineVars.Keys) { $names[[string]$name] = $true }
        foreach ($name in $userVars.Keys) { $names[[string]$name] = $true }

        foreach ($name in ($names.Keys | Sort-Object)) {
            if ($name.Equals('Path', [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $effective = Get-EffectiveEnvironmentValue -Name $name -UserVariables $userVars -MachineVariables $machineVars
            if (-not $effective.found) {
                $skippedCount++
                $operations += [pscustomobject]@{
                    variable = $name
                    whatIf   = [bool]$WhatIf
                    changed  = $false
                    skipped  = $true
                    reason   = 'missing'
                }
                continue
            }

            $current = [Environment]::GetEnvironmentVariable($name, 'Process')
            $newValue = [string]$effective.value
            $changed = $current -ne $newValue

            if (-not $WhatIf -and $changed) {
                [Environment]::SetEnvironmentVariable($name, $newValue, 'Process')
            }

            if ($changed) { $changedCount++ }

            $operations += [pscustomobject]@{
                variable = $name
                whatIf   = [bool]$WhatIf
                changed  = $changed
                source   = $effective.source
                value    = $newValue
            }
        }
    }
    else {
        if ($scopeValue.Equals('path', [System.StringComparison]::OrdinalIgnoreCase)) {
            $pathArgs = @{ WhatIf = [bool]$WhatIf }
            if ($PSBoundParameters.ContainsKey('UserPathValue')) { $pathArgs['UserPathValue'] = $UserPathValue }
            if ($PSBoundParameters.ContainsKey('MachinePathValue')) { $pathArgs['MachinePathValue'] = $MachinePathValue }

            $pathResult = Invoke-PathRefresh @pathArgs
            $operations += $pathResult
            if ($pathResult.changed) { $changedCount++ }
        }
        else {
            $effective = Get-EffectiveEnvironmentValue -Name $scopeValue -UserVariables $userVars -MachineVariables $machineVars
            if (-not $effective.found) {
                $skippedCount++
                $operations += [pscustomobject]@{
                    variable = $scopeValue
                    whatIf   = [bool]$WhatIf
                    changed  = $false
                    skipped  = $true
                    reason   = 'missing'
                }
            }
            else {
                $current = [Environment]::GetEnvironmentVariable($scopeValue, 'Process')
                $newValue = [string]$effective.value
                $changed = $current -ne $newValue

                if (-not $WhatIf -and $changed) {
                    [Environment]::SetEnvironmentVariable($scopeValue, $newValue, 'Process')
                }

                if ($changed) { $changedCount++ }

                $operations += [pscustomobject]@{
                    variable = $scopeValue
                    whatIf   = [bool]$WhatIf
                    changed  = $changed
                    source   = $effective.source
                    value    = $newValue
                }
            }
        }
    }

    return [pscustomobject]@{
        refreshedAt   = (Get-Date).ToUniversalTime().ToString('o')
        scope         = $scopeValue
        whatIf        = [bool]$WhatIf
        changedCount  = $changedCount
        skippedCount  = $skippedCount
        operationCount = $operations.Count
        operations    = $operations
        message       = if ($WhatIf) {
            "WhatIf: Would refresh process environment for scope '$scopeValue'."
        } else {
            "Refreshed process environment for scope '$scopeValue'."
        }
    }
}

Export-ModuleMember -Function Get-ScopeEnvironmentMap, Get-EffectiveEnvironmentValue, Merge-PathFromScopes, Invoke-PathRefresh, Invoke-EnvironmentRefresh
