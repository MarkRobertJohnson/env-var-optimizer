Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathSource.psm1') -DisableNameChecking

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
    if (-not $WhatIf) {
        $snapshotResult = New-PathSnapshot -Directory $BackupDir
    }

    if ($userChanged) {
        Set-PathValue -Scope User -Value ([string]$plan.proposedUserPath) -WhatIf:$WhatIf
    }

    if ($machineChanged) {
        Set-PathValue -Scope Machine -Value ([string]$plan.proposedMachinePath) -WhatIf:$WhatIf
    }

    return [pscustomobject]@{
        appliedAt           = (Get-Date).ToUniversalTime().ToString('o')
        whatIf              = [bool]$WhatIf
        planPath            = (Resolve-Path -LiteralPath $PlanPath).Path
        planHash            = $plan.planHash
        changedUserPath     = $userChanged
        changedMachinePath  = $machineChanged
        snapshotPath        = if ($snapshotResult) { $snapshotResult.snapshotPath } else { $null }
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

    Set-PathValue -Scope User -Value ([string]$snapshot.userPath) -WhatIf:$WhatIf
    Set-PathValue -Scope Machine -Value ([string]$snapshot.machinePath) -WhatIf:$WhatIf

    return [pscustomobject]@{
        rolledBackAt  = (Get-Date).ToUniversalTime().ToString('o')
        whatIf        = [bool]$WhatIf
        snapshotPath  = (Resolve-Path -LiteralPath $SnapshotPath).Path
        message       = 'Rollback complete. Open new shell sessions to use restored PATH values.'
    }
}

Export-ModuleMember -Function Invoke-PathPlanApply, Invoke-PathRollback, Read-PlanFile
