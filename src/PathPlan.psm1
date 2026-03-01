Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathClassify.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathSource.psm1') -DisableNameChecking

function Get-PathEntryId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Scope,
        [Parameter(Mandatory)]
        [int]$Index
    )

    return "$Scope`:$Index"
}

function Get-RequiredPathKeys {
    [CmdletBinding()]
    param()

    $requiredPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $requiredPaths += (Join-Path $env:SystemRoot 'System32')
        $requiredPaths += $env:SystemRoot
        $requiredPaths += (Join-Path $env:SystemRoot 'System32\Wbem')
    }

    return @(
        $requiredPaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { Get-CanonicalPathKey -Path $_ } |
            Sort-Object -Unique
    )
}

function Get-ObjectSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Object
    )

    $json = $Object | ConvertTo-Json -Depth 16 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
}

function New-ScopedClassifiedEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$UserEntries,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$MachineEntries
    )

    $entries = @()
    for ($i = 0; $i -lt $MachineEntries.Count; $i++) {
        $entries += [pscustomobject]@{
            Scope       = 'Machine'
            Index       = $i
            GlobalOrder = $i
            Original    = $MachineEntries[$i]
        }
    }

    $offset = $MachineEntries.Count
    for ($i = 0; $i -lt $UserEntries.Count; $i++) {
        $entries += [pscustomobject]@{
            Scope       = 'User'
            Index       = $i
            GlobalOrder = $offset + $i
            Original    = $UserEntries[$i]
        }
    }

    $classified = @()
    foreach ($entry in $entries) {
        $classified += Get-PathEntryClassification -Entry $entry
    }

    return $classified
}

function Resolve-GroupKeeper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$Group,
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Machine')]
        [string]$TargetScope
    )

    $usable = @(
        $Group |
            Where-Object { -not $_.IsEmpty -and $_.ExistenceStatus -ne 'Missing' } |
            Sort-Object GlobalOrder
    )

    if ($usable.Count -eq 0) {
        return $null
    }

    $preferred = @($usable | Where-Object { $_.Scope -eq $TargetScope })
    if ($preferred.Count -gt 0) {
        return $preferred[0]
    }

    return $usable[0]
}

function New-PathOptimizationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$UserEntries,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$MachineEntries,
        [ValidateSet('user', 'machine', 'both')]
        [string]$Scope = 'both',
        [ValidateSet('SharedToMachine')]
        [string]$ScopePolicy = 'SharedToMachine'
    )

    $scopeNormalized = $Scope.ToLowerInvariant()
    $classified = New-ScopedClassifiedEntries -UserEntries $UserEntries -MachineEntries $MachineEntries

    $planEntries = @()
    $entryMap = @{}
    foreach ($entry in $classified) {
        $planEntry = [pscustomobject]@{
            original       = $entry.Original
            normalized     = $entry.Normalized
            scope          = $entry.Scope
            index          = $entry.Index
            exists         = $entry.Exists
            kind           = $entry.Kind
            status         = 'keep'
            reason         = 'unchanged'
            canonical      = $entry.Canonical
            globalOrder    = $entry.GlobalOrder
            existenceState = $entry.ExistenceStatus
            staleAccount   = $entry.StaleAccount
            referencedUser = $entry.ReferencedUser
        }
        $planEntries += $planEntry
        $entryMap[(Get-PathEntryId -Scope $entry.Scope -Index $entry.Index)] = $planEntry
    }

    $quarantine = @()
    $proposedMachine = @()
    $proposedUser = @()

    $selectedGroups = @()

    switch ($scopeNormalized) {
        'both' {
            $selectedGroups = @(
                $classified |
                    Group-Object Canonical |
                    Sort-Object { ($_.Group | Measure-Object -Property GlobalOrder -Minimum).Minimum }
            )
        }
        'user' {
            $selectedGroups = @(
                $classified |
                    Where-Object { $_.Scope -eq 'User' } |
                    Group-Object Canonical |
                    Sort-Object { ($_.Group | Measure-Object -Property GlobalOrder -Minimum).Minimum }
            )
            $proposedMachine = @($MachineEntries)
            foreach ($machineEntry in ($classified | Where-Object Scope -eq 'Machine')) {
                $entryMap[(Get-PathEntryId -Scope 'Machine' -Index $machineEntry.Index)].reason = 'scope_not_selected'
            }
        }
        'machine' {
            $selectedGroups = @(
                $classified |
                    Where-Object { $_.Scope -eq 'Machine' } |
                    Group-Object Canonical |
                    Sort-Object { ($_.Group | Measure-Object -Property GlobalOrder -Minimum).Minimum }
            )
            $proposedUser = @($UserEntries)
            foreach ($userEntry in ($classified | Where-Object Scope -eq 'User')) {
                $entryMap[(Get-PathEntryId -Scope 'User' -Index $userEntry.Index)].reason = 'scope_not_selected'
            }
        }
    }

    foreach ($groupObj in $selectedGroups) {
        $group = @($groupObj.Group | Sort-Object GlobalOrder)

        $isCanonicalEmpty = [string]::IsNullOrWhiteSpace($groupObj.Name)
        if ($isCanonicalEmpty) {
            foreach ($entry in $group) {
                $mapEntry = $entryMap[(Get-PathEntryId -Scope $entry.Scope -Index $entry.Index)]
                $mapEntry.status = 'remove_missing'
                $mapEntry.reason = 'empty_path_entry'
                $quarantine += [pscustomobject]@{
                    original       = $entry.Original
                    normalized     = $entry.Normalized
                    scope          = $entry.Scope
                    reason         = 'empty_path_entry'
                    quarantinedAt  = (Get-Date).ToUniversalTime().ToString('o')
                }
            }
            continue
        }

        $scopesInGroup = @($group | Select-Object -ExpandProperty Scope -Unique)
        $targetScope = $scopesInGroup[0]

        if ($scopeNormalized -eq 'both' -and $scopesInGroup.Count -gt 1 -and $ScopePolicy -eq 'SharedToMachine') {
            $targetScope = 'Machine'
        }

        if ($scopeNormalized -eq 'user') {
            $targetScope = 'User'
        }
        elseif ($scopeNormalized -eq 'machine') {
            $targetScope = 'Machine'
        }

        $keeper = Resolve-GroupKeeper -Group $group -TargetScope $targetScope
        if ($null -eq $keeper) {
            foreach ($entry in $group) {
                $mapEntry = $entryMap[(Get-PathEntryId -Scope $entry.Scope -Index $entry.Index)]
                $mapEntry.status = 'remove_missing'
                $mapEntry.reason = 'nonexistent_path'
                $quarantine += [pscustomobject]@{
                    original      = $entry.Original
                    normalized    = $entry.Normalized
                    scope         = $entry.Scope
                    reason        = 'nonexistent_path'
                    quarantinedAt = (Get-Date).ToUniversalTime().ToString('o')
                }
            }
            continue
        }

        foreach ($entry in $group) {
            $mapEntry = $entryMap[(Get-PathEntryId -Scope $entry.Scope -Index $entry.Index)]

            if ($entry.Scope -eq $keeper.Scope -and $entry.Index -eq $keeper.Index) {
                if ($entry.Scope -eq $targetScope) {
                    $mapEntry.status = 'keep'
                    $mapEntry.reason = 'selected_keeper'
                }
                else {
                    $mapEntry.status = 'move_scope'
                    $mapEntry.reason = "moved_to_$($targetScope.ToLowerInvariant())"
                }

                if ($targetScope -eq 'Machine') {
                    $proposedMachine += [pscustomobject]@{ path = $keeper.Normalized; order = $keeper.GlobalOrder }
                }
                else {
                    $proposedUser += [pscustomobject]@{ path = $keeper.Normalized; order = $keeper.GlobalOrder }
                }

                continue
            }

            if ($entry.IsEmpty -or $entry.ExistenceStatus -eq 'Missing') {
                $mapEntry.status = 'remove_missing'
                $mapEntry.reason = 'nonexistent_or_empty'
                $quarantine += [pscustomobject]@{
                    original      = $entry.Original
                    normalized    = $entry.Normalized
                    scope         = $entry.Scope
                    reason        = 'nonexistent_or_empty'
                    quarantinedAt = (Get-Date).ToUniversalTime().ToString('o')
                }
            }
            else {
                $mapEntry.status = 'remove_duplicate'
                $mapEntry.reason = 'duplicate_normalized_entry'
            }
        }
    }

    $finalMachineEntries = @()
    $finalUserEntries = @()

    if ($scopeNormalized -eq 'both' -or $scopeNormalized -eq 'machine') {
        $finalMachineEntries = @(
            $proposedMachine |
                Sort-Object order |
                Select-Object -ExpandProperty path
        )
    }
    else {
        $finalMachineEntries = @($proposedMachine)
    }

    if ($scopeNormalized -eq 'both' -or $scopeNormalized -eq 'user') {
        $finalUserEntries = @(
            $proposedUser |
                Sort-Object order |
                Select-Object -ExpandProperty path
        )
    }
    else {
        $finalUserEntries = @($proposedUser)
    }

    if ($scopeNormalized -eq 'user') {
        if ($finalUserEntries.Count -eq 0) {
            $finalUserEntries = @(
                $planEntries |
                    Where-Object { $_.scope -eq 'User' -and ($_.status -eq 'keep' -or $_.status -eq 'move_scope') } |
                    Sort-Object globalOrder |
                    Select-Object -ExpandProperty normalized
            )
        }
    }

    if ($scopeNormalized -eq 'machine') {
        if ($finalMachineEntries.Count -eq 0) {
            $finalMachineEntries = @(
                $planEntries |
                    Where-Object { $_.scope -eq 'Machine' -and ($_.status -eq 'keep' -or $_.status -eq 'move_scope') } |
                    Sort-Object globalOrder |
                    Select-Object -ExpandProperty normalized
            )
        }
    }

    $finalMachineEntries = @($finalMachineEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $finalUserEntries = @($finalUserEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $proposedMachinePath = $finalMachineEntries -join ';'
    $proposedUserPath = $finalUserEntries -join ';'

    $warnings = @()
    if ([string]::IsNullOrWhiteSpace($proposedMachinePath) -and [string]::IsNullOrWhiteSpace($proposedUserPath)) {
        $warnings += 'Both Machine and User PATH would become empty.'
    }

    $combinedCanonical = @(
        @($finalMachineEntries + $finalUserEntries) |
            ForEach-Object { Get-CanonicalPathKey -Path $_ } |
            Sort-Object -Unique
    )

    $requiredKeys = Get-RequiredPathKeys
    foreach ($requiredKey in $requiredKeys) {
        if ($combinedCanonical -notcontains $requiredKey) {
            $warnings += "Required system path appears missing from proposed PATH: $requiredKey"
        }
    }

    $shellDir = Get-CurrentShellPathDirectory
    if (-not [string]::IsNullOrWhiteSpace($shellDir)) {
        $shellKey = Get-CanonicalPathKey -Path $shellDir
        if ($combinedCanonical -notcontains $shellKey) {
            $warnings += "Current shell directory is missing from proposed PATH: $shellDir"
        }
    }

    $statusCounts = @{}
    foreach ($status in @($planEntries | Select-Object -ExpandProperty status)) {
        if (-not $statusCounts.ContainsKey($status)) {
            $statusCounts[$status] = 0
        }

        $statusCounts[$status]++
    }

    $planCore = [pscustomobject]@{
        version      = 1
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        source       = [pscustomobject]@{
            scopeMode          = $scopeNormalized
            scopePolicy        = $ScopePolicy
            computerName       = $env:COMPUTERNAME
            currentUser        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            isAdministrator    = Test-IsAdministrator
            userPathLength     = ($UserEntries -join ';').Length
            machinePathLength  = ($MachineEntries -join ';').Length
            userEntryCount     = $UserEntries.Count
            machineEntryCount  = $MachineEntries.Count
        }
        entries             = @($planEntries)
        proposedUserEntries = @($finalUserEntries)
        proposedMachineEntries = @($finalMachineEntries)
        proposedUserPath    = $proposedUserPath
        proposedMachinePath = $proposedMachinePath
        quarantine          = @($quarantine)
        snapshots           = @()
        shims               = @()
        summary             = [pscustomobject]@{
            beforeUserLength      = ($UserEntries -join ';').Length
            beforeMachineLength   = ($MachineEntries -join ';').Length
            afterUserLength       = $proposedUserPath.Length
            afterMachineLength    = $proposedMachinePath.Length
            beforeCombinedLength  = (($UserEntries -join ';').Length + ($MachineEntries -join ';').Length)
            afterCombinedLength   = ($proposedUserPath.Length + $proposedMachinePath.Length)
            entriesProcessed      = $planEntries.Count
            quarantineCount       = $quarantine.Count
            statusCounts          = $statusCounts
            warnings              = @($warnings)
        }
    }

    $hashPayload = $planCore | ConvertTo-Json -Depth 32 | ConvertFrom-Json
    $hashPayload.generatedAt = ''
    foreach ($item in @($hashPayload.quarantine)) {
        $item.quarantinedAt = ''
    }
    $planHash = Get-ObjectSha256 -Object $hashPayload
    $planCore | Add-Member -NotePropertyName planHash -NotePropertyValue $planHash

    return $planCore
}

Export-ModuleMember -Function New-PathOptimizationPlan, Get-RequiredPathKeys
