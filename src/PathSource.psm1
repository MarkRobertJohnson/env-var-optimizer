Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -DisableNameChecking

function Test-IsAdministrator {
    [CmdletBinding()]
    param()

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine', 'Process')]
        [string]$Scope
    )

    $value = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if ($null -eq $value) {
        return ''
    }

    return $value
}

function Set-PathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        return
    }

    if ($Scope -eq 'Machine' -and -not (Test-IsAdministrator)) {
        throw 'Updating Machine PATH requires an elevated PowerShell session.'
    }

    [Environment]::SetEnvironmentVariable('Path', $Value, $Scope)
}

function Get-PathEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine', 'Process')]
        [string]$Scope
    )

    $rawValue = Get-PathValue -Scope $Scope
    $parts = Split-PathVariableValue -Value $rawValue

    $result = @()
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $normalized = Normalize-PathEntry -Path $parts[$i]
        $result += [pscustomobject]@{
            Scope      = $Scope
            Index      = $i
            Original   = $parts[$i]
            Trimmed    = $normalized.Trimmed
            Normalized = $normalized.Normalized
            Canonical  = $normalized.Canonical
            IsEmpty    = $normalized.IsEmpty
        }
    }

    return $result
}

function Get-EnvironmentPathState {
    [CmdletBinding()]
    param()

    $user = Get-PathValue -Scope User
    $machine = Get-PathValue -Scope Machine
    $process = Get-PathValue -Scope Process

    return [pscustomobject]@{
        generatedAt        = (Get-Date).ToUniversalTime().ToString('o')
        computerName       = $env:COMPUTERNAME
        currentUser        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        isAdministrator    = (Test-IsAdministrator)
        userPath           = $user
        machinePath        = $machine
        processPath        = $process
        userPathLength     = $user.Length
        machinePathLength  = $machine.Length
        processPathLength  = $process.Length
        userEntryCount     = (Split-PathVariableValue -Value $user).Count
        machineEntryCount  = (Split-PathVariableValue -Value $machine).Count
        processEntryCount  = (Split-PathVariableValue -Value $process).Count
    }
}

function New-PathSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $filePath = Join-Path $Directory ("path-snapshot-$timestamp.json")

    $snapshot = [pscustomobject]@{
        version      = 1
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        computerName = $env:COMPUTERNAME
        currentUser  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        userPath     = Get-PathValue -Scope User
        machinePath  = Get-PathValue -Scope Machine
        processPath  = Get-PathValue -Scope Process
    }

    $snapshot | ConvertTo-Json -Depth 8 | Set-Content -Path $filePath -Encoding UTF8

    return [pscustomobject]@{
        snapshotPath = $filePath
        snapshot     = $snapshot
    }
}

function Read-PathSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Snapshot file not found: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-CurrentShellPathDirectory {
    [CmdletBinding()]
    param()

    $cmd = Get-Command -Name pwsh -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }

    return [System.IO.Path]::GetDirectoryName($cmd.Source)
}

# Windows PATH length limits (conservative values for broad compatibility)
$script:PathLengthLimits = @{
    # User/Machine PATH registry value practical limit
    ScopeWarning = 2048
    ScopeCritical = 4096
    # Total process PATH limit
    ProcessWarning = 8192
    ProcessCritical = 32767
}

function Get-PathLengthWarnings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ProposedValue
    )

    $warnings = @()
    $length = $ProposedValue.Length

    # Check scope-specific limits
    if ($length -ge $script:PathLengthLimits.ScopeCritical) {
        $warnings += [pscustomobject]@{
            Level   = 'Critical'
            Message = "$Scope PATH length ($length chars) exceeds critical limit ($($script:PathLengthLimits.ScopeCritical) chars). Some applications may fail to read the full PATH."
        }
    }
    elseif ($length -ge $script:PathLengthLimits.ScopeWarning) {
        $warnings += [pscustomobject]@{
            Level   = 'Warning'
            Message = "$Scope PATH length ($length chars) exceeds recommended limit ($($script:PathLengthLimits.ScopeWarning) chars). Consider consolidating entries."
        }
    }

    # Check combined process PATH impact
    $currentUser = Get-PathValue -Scope User
    $currentMachine = Get-PathValue -Scope Machine
    
    $combinedLength = if ($Scope -eq 'User') {
        $ProposedValue.Length + 1 + $currentMachine.Length  # +1 for separator
    } else {
        $currentUser.Length + 1 + $ProposedValue.Length
    }

    if ($combinedLength -ge $script:PathLengthLimits.ProcessCritical) {
        $warnings += [pscustomobject]@{
            Level   = 'Critical'
            Message = "Combined PATH length ($combinedLength chars) exceeds Windows process limit ($($script:PathLengthLimits.ProcessCritical) chars). PATH will be truncated at runtime."
        }
    }
    elseif ($combinedLength -ge $script:PathLengthLimits.ProcessWarning) {
        $warnings += [pscustomobject]@{
            Level   = 'Warning'
            Message = "Combined PATH length ($combinedLength chars) is approaching system limits. Consider running 'pathopt.ps1 plan' to optimize."
        }
    }

    return $warnings
}

function Add-PathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$Scope,
        [ValidateSet('Prepend', 'Append')]
        [string]$Position = 'Append',
        [switch]$Force,
        [switch]$WhatIf
    )

    $result = [pscustomobject]@{
        addedAt       = (Get-Date).ToUniversalTime().ToString('o')
        path          = $Path
        scope         = $Scope
        position      = $Position
        whatIf        = [bool]$WhatIf
        alreadyExists = $false
        added         = $false
        warnings      = @()
        newLength     = 0
        message       = ''
    }

    # Validate the path entry
    $normalizedEntry = Normalize-PathEntry -Path $Path
    if ($normalizedEntry.IsEmpty) {
        throw 'Cannot add an empty path entry.'
    }

    # Check if path already exists
    $currentValue = Get-PathValue -Scope $Scope
    $currentEntries = Split-PathVariableValue -Value $currentValue
    $canonicalNew = $normalizedEntry.Canonical

    foreach ($entry in $currentEntries) {
        $existingCanonical = (Normalize-PathEntry -Path $entry).Canonical
        if ($existingCanonical -eq $canonicalNew) {
            $result.alreadyExists = $true
            $result.message = "Path '$Path' already exists in $Scope PATH."
            if (-not $Force) {
                return $result
            }
        }
    }

    # Check if elevated for Machine scope
    if ($Scope -eq 'Machine' -and -not (Test-IsAdministrator) -and -not $WhatIf) {
        throw 'Adding to Machine PATH requires an elevated PowerShell session.'
    }

    # Build new PATH value
    $trimmedPath = $normalizedEntry.Trimmed
    $newEntries = if ($Position -eq 'Prepend') {
        @($trimmedPath) + $currentEntries
    } else {
        $currentEntries + @($trimmedPath)
    }

    $newValue = Join-PathVariableValue -Entries $newEntries
    $result.newLength = $newValue.Length

    # Check for length warnings
    $result.warnings = @(Get-PathLengthWarnings -Scope $Scope -ProposedValue $newValue)

    # Check for critical warnings that should block unless forced
    $criticalWarnings = @($result.warnings | Where-Object { $_.Level -eq 'Critical' })
    if ($criticalWarnings.Count -gt 0 -and -not $Force -and -not $WhatIf) {
        $result.message = "Operation blocked due to critical path length warnings. Use --force to override."
        return $result
    }

    # Apply the change
    if (-not $WhatIf) {
        Set-PathValue -Scope $Scope -Value $newValue
    }

    $result.added = $true
    $result.message = if ($WhatIf) {
        "WhatIf: Would add '$Path' to $Scope PATH ($Position). New length: $($result.newLength) chars."
    } else {
        "Added '$Path' to $Scope PATH ($Position). New length: $($result.newLength) chars. Open new shell sessions to use updated PATH."
    }

    return $result
}

Export-ModuleMember -Function Test-IsAdministrator, Get-PathValue, Set-PathValue, Get-PathEntries, Get-EnvironmentPathState, New-PathSnapshot, Read-PathSnapshot, Get-CurrentShellPathDirectory, Get-PathLengthWarnings, Add-PathEntry
