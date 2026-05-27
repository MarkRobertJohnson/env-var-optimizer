Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathSource.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -DisableNameChecking

function Get-UniqueTrimmedPathEntries {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Entries
    )

    $seen = @{}
    $kept = @()

    foreach ($entry in @($Entries)) {
        $normalized = Normalize-PathEntry -Path $entry
        if ($normalized.IsEmpty) {
            continue
        }

        if ($seen.ContainsKey($normalized.Canonical)) {
            continue
        }

        $seen[$normalized.Canonical] = $true
        $kept += $normalized.Trimmed
    }

    return $kept
}

function Get-RollbackRetainedEntries {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$SnapshotMachinePath,
        [AllowEmptyString()]
        [string]$SnapshotUserPath,
        [AllowEmptyString()]
        [string]$CurrentMachinePath,
        [AllowEmptyString()]
        [string]$CurrentUserPath
    )

    $snapshotKeys = @{}
    foreach ($entry in @(@(Split-PathVariableValue -Value $SnapshotMachinePath) + @(Split-PathVariableValue -Value $SnapshotUserPath))) {
        $normalized = Normalize-PathEntry -Path $entry
        if ($normalized.IsEmpty) {
            continue
        }

        $snapshotKeys[$normalized.Canonical] = $true
    }

    $retainedKeys = @{}
    $retainedMachineEntries = @()
    $retainedUserEntries = @()

    foreach ($entry in @(@(Split-PathVariableValue -Value $CurrentMachinePath))) {
        $normalized = Normalize-PathEntry -Path $entry
        if ($normalized.IsEmpty) {
            continue
        }

        if ($snapshotKeys.ContainsKey($normalized.Canonical) -or $retainedKeys.ContainsKey($normalized.Canonical)) {
            continue
        }

        $retainedKeys[$normalized.Canonical] = $true
        $retainedMachineEntries += $normalized.Trimmed
    }

    foreach ($entry in @(@(Split-PathVariableValue -Value $CurrentUserPath))) {
        $normalized = Normalize-PathEntry -Path $entry
        if ($normalized.IsEmpty) {
            continue
        }

        if ($snapshotKeys.ContainsKey($normalized.Canonical) -or $retainedKeys.ContainsKey($normalized.Canonical)) {
            continue
        }

        $retainedKeys[$normalized.Canonical] = $true
        $retainedUserEntries += $normalized.Trimmed
    }

    return [pscustomobject]@{
        machineEntries = $retainedMachineEntries
        userEntries    = $retainedUserEntries
        totalCount     = @($retainedMachineEntries).Count + @($retainedUserEntries).Count
    }
}

function Get-MergedRollbackPaths {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$SnapshotMachinePath,
        [AllowEmptyString()]
        [string]$SnapshotUserPath,
        [AllowEmptyString()]
        [string]$CurrentMachinePath,
        [AllowEmptyString()]
        [string]$CurrentUserPath
    )

    $retained = Get-RollbackRetainedEntries -SnapshotMachinePath $SnapshotMachinePath -SnapshotUserPath $SnapshotUserPath -CurrentMachinePath $CurrentMachinePath -CurrentUserPath $CurrentUserPath
    $snapshotMachineEntries = @(@(Split-PathVariableValue -Value $SnapshotMachinePath))
    $snapshotUserEntries = @(@(Split-PathVariableValue -Value $SnapshotUserPath))

    $mergedMachineEntries = @($snapshotMachineEntries + $retained.machineEntries)
    $mergedUserEntries = @($snapshotUserEntries + $retained.userEntries)

    return [pscustomobject]@{
        machinePath               = Join-PathVariableValue -Entries $mergedMachineEntries
        userPath                  = Join-PathVariableValue -Entries $mergedUserEntries
        retainedMachineEntries    = (Get-UniqueTrimmedPathEntries -Entries $retained.machineEntries)
        retainedUserEntries       = (Get-UniqueTrimmedPathEntries -Entries $retained.userEntries)
    }
}

function Test-PathWarningsContainCritical {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Warnings
    )

    return @($Warnings | Where-Object { $_.Level -eq 'Critical' }).Count -gt 0
}

function Read-PlanFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath
    )

    if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        throw "Plan file not found: $PlanPath"
    }

    return Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
}

function Invoke-PathPlanApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlanPath,
        [string]$BackupDir = (Join-Path (Get-Location) '.pathopt\\backups'),
        [switch]$WhatIf
    )

    $plan = Read-PlanFile -PlanPath $PlanPath
    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath).Path

    if ($null -eq $plan.proposedUserPath -or $null -eq $plan.proposedMachinePath) {
        throw 'Plan file is missing proposedUserPath and/or proposedMachinePath.'
    }

    $currentUserPath = Get-PathValue -Scope User
    $currentMachinePath = Get-PathValue -Scope Machine

    $userChanged = $currentUserPath -ne [string]$plan.proposedUserPath
    $machineChanged = $currentMachinePath -ne [string]$plan.proposedMachinePath

    if ($machineChanged -and -not (Test-IsAdministrator) -and -not $WhatIf) {
        throw 'Machine PATH change requested, but the shell is not elevated.'
    }

    $snapshotResult = $null
    $postApplySnapshotResult = $null
    if (-not $WhatIf) {
        $snapshotResult = New-PathSnapshot -Directory $BackupDir -Reason 'pre-apply' -PlanPath $resolvedPlanPath -PlanHash $plan.planHash
    }

    if ($userChanged) {
        Set-PathValue -Scope User -Value ([string]$plan.proposedUserPath) -WhatIf:$WhatIf
    }

    if ($machineChanged) {
        Set-PathValue -Scope Machine -Value ([string]$plan.proposedMachinePath) -WhatIf:$WhatIf
    }

    if (-not $WhatIf -and ($userChanged -or $machineChanged)) {
        $postApplySnapshotResult = New-PathSnapshot -Directory $BackupDir -Reason 'post-apply' -PlanPath $resolvedPlanPath -PlanHash $plan.planHash
    }

    return [pscustomobject]@{
        appliedAt           = (Get-Date).ToUniversalTime().ToString('o')
        whatIf              = [bool]$WhatIf
        planPath            = $resolvedPlanPath
        planHash            = $plan.planHash
        changedUserPath     = $userChanged
        changedMachinePath  = $machineChanged
        snapshotPath        = if ($snapshotResult) { $snapshotResult.snapshotPath } else { $null }
        postApplySnapshotPath = if ($postApplySnapshotResult) { $postApplySnapshotResult.snapshotPath } else { $null }
        message             = 'Apply complete. Open new shell sessions to use updated PATH values.'
    }
}

function Invoke-PathRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,
        [switch]$WhatIf
    )

    $snapshot = Read-PathSnapshot -Path $SnapshotPath

    if ($null -eq $snapshot.userPath -or $null -eq $snapshot.machinePath) {
        throw 'Snapshot file is missing userPath and/or machinePath.'
    }

    if (-not (Test-IsAdministrator) -and -not $WhatIf) {
        throw 'Rollback updates Machine PATH and requires an elevated shell.'
    }

    $currentUserPath = Get-PathValue -Scope User
    $currentMachinePath = Get-PathValue -Scope Machine
    $mergedPaths = Get-MergedRollbackPaths -SnapshotMachinePath ([string]$snapshot.machinePath) -SnapshotUserPath ([string]$snapshot.userPath) -CurrentMachinePath $currentMachinePath -CurrentUserPath $currentUserPath
    $retainedMachineEntries = @($mergedPaths.retainedMachineEntries)
    $retainedUserEntries = @($mergedPaths.retainedUserEntries)

    $warnings = @()
    $warnings += @(Get-PathLengthWarnings -Scope User -ProposedValue $mergedPaths.userPath)
    $warnings += @(Get-PathLengthWarnings -Scope Machine -ProposedValue $mergedPaths.machinePath)

    if (-not $WhatIf -and (Test-PathWarningsContainCritical -Warnings $warnings)) {
        throw 'Rollback would exceed critical PATH length limits after retaining newer entries. Use a newer snapshot or remove retained entries before retrying.'
    }

    Set-PathValue -Scope User -Value $mergedPaths.userPath -WhatIf:$WhatIf
    Set-PathValue -Scope Machine -Value $mergedPaths.machinePath -WhatIf:$WhatIf

    return [pscustomobject]@{
        rolledBackAt              = (Get-Date).ToUniversalTime().ToString('o')
        whatIf                    = [bool]$WhatIf
        exact                     = $false
        snapshotPath              = (Resolve-Path -LiteralPath $SnapshotPath).Path
        retainedEntryCount        = @($retainedMachineEntries).Count + @($retainedUserEntries).Count
        retainedMachineEntryCount = @($retainedMachineEntries).Count
        retainedUserEntryCount    = @($retainedUserEntries).Count
        retainedMachineEntries    = $retainedMachineEntries
        retainedUserEntries       = $retainedUserEntries
        warnings                  = $warnings
        message                   = 'Rollback complete. Open new shell sessions to use restored PATH values while retaining newer PATH entries.'
    }
}

Export-ModuleMember -Function Invoke-PathPlanApply, Invoke-PathRollback, Read-PlanFile
