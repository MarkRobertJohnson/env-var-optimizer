Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -DisableNameChecking

function Get-PathExistence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            return [pscustomobject]@{ exists = $true; status = 'Present'; kind = 'directory'; error = $null }
        }

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return [pscustomobject]@{ exists = $true; status = 'Present'; kind = 'file'; error = $null }
        }

        return [pscustomobject]@{ exists = $false; status = 'Missing'; kind = 'unknown'; error = $null }
    }
    catch {
        return [pscustomobject]@{ exists = $false; status = 'Unknown'; kind = 'unknown'; error = $_.Exception.Message }
    }
}

function Test-StaleAccountPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$CurrentUserName = $env:USERNAME
    )

    $match = [regex]::Match($Path, '(?i)[\\/]users[\\/]([^\\/]+)')
    if (-not $match.Success) {
        return [pscustomobject]@{ isStale = $false; referencedUser = $null }
    }

    $referencedUser = $match.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($CurrentUserName)) {
        return [pscustomobject]@{ isStale = $false; referencedUser = $referencedUser }
    }

    $isStale = -not $referencedUser.Equals($CurrentUserName, [System.StringComparison]::OrdinalIgnoreCase)
    return [pscustomobject]@{ isStale = $isStale; referencedUser = $referencedUser }
}

function Get-PathEntryClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Entry,
        [string]$CurrentUserName = $env:USERNAME
    )

    $normalized = Normalize-PathEntry -Path $Entry.Original
    if ($normalized.IsEmpty) {
        return [pscustomobject]@{
            Scope          = $Entry.Scope
            Index          = $Entry.Index
            GlobalOrder    = $Entry.GlobalOrder
            Original       = $Entry.Original
            Trimmed        = $normalized.Trimmed
            Normalized     = ''
            Canonical      = ''
            IsEmpty        = $true
            Exists         = $false
            ExistenceStatus = 'Missing'
            Kind           = 'unknown'
            AccessError    = $null
            StaleAccount   = $false
            ReferencedUser = $null
        }
    }

    $existence = Get-PathExistence -Path $normalized.Expanded
    $stale = Test-StaleAccountPath -Path $normalized.Expanded -CurrentUserName $CurrentUserName

    return [pscustomobject]@{
        Scope           = $Entry.Scope
        Index           = $Entry.Index
        GlobalOrder     = $Entry.GlobalOrder
        Original        = $Entry.Original
        Trimmed         = $normalized.Trimmed
        Expanded        = $normalized.Expanded
        Normalized      = $normalized.Normalized
        Canonical       = $normalized.Canonical
        IsEmpty         = $false
        Exists          = $existence.exists
        ExistenceStatus = $existence.status
        Kind            = $existence.kind
        AccessError     = $existence.error
        StaleAccount    = $stale.isStale
        ReferencedUser  = $stale.referencedUser
    }
}

function Find-CommandCollisions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject[]]$ClassifiedEntries
    )

    $pathExtRaw = $env:PATHEXT
    if ([string]::IsNullOrWhiteSpace($pathExtRaw)) {
        $extensions = @('.exe', '.cmd', '.bat', '.com', '.ps1')
    }
    else {
        $extensions = $pathExtRaw.Split(';') | ForEach-Object { $_.ToLowerInvariant() }
    }

    $directories = @(
        $ClassifiedEntries |
            Where-Object { $_.Exists -and $_.Kind -eq 'directory' -and -not [string]::IsNullOrWhiteSpace($_.Expanded) } |
            Sort-Object GlobalOrder |
            Select-Object -ExpandProperty Expanded -Unique
    )

    $commandMap = @{}

    foreach ($dir in $directories) {
        try {
            $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop
        }
        catch {
            continue
        }

        foreach ($file in $files) {
            $ext = $file.Extension.ToLowerInvariant()
            if ($extensions -notcontains $ext) {
                continue
            }

            $commandName = $file.BaseName.ToLowerInvariant()
            if (-not $commandMap.ContainsKey($commandName)) {
                $commandMap[$commandName] = @()
            }

            $commandMap[$commandName] += [pscustomobject]@{
                command = $commandName
                file    = $file.FullName
                dir     = $dir
            }
        }
    }

    $collisions = @()
    foreach ($name in ($commandMap.Keys | Sort-Object)) {
        $locations = @($commandMap[$name])
        $dirCount = @($locations | Select-Object -ExpandProperty dir -Unique).Count
        if ($dirCount -gt 1) {
            $collisions += [pscustomobject]@{
                command   = $name
                count     = $locations.Count
                locations = @($locations)
            }
        }
    }

    return $collisions
}

function Get-PathDiagnostics {
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
        [switch]$IncludeCollisions
    )

    $classified = @()
    $machineEntriesObj = @()
    for ($i = 0; $i -lt $MachineEntries.Count; $i++) {
        $machineEntriesObj += [pscustomobject]@{ Scope = 'Machine'; Index = $i; GlobalOrder = $i; Original = $MachineEntries[$i] }
    }

    $offset = $MachineEntries.Count
    $userEntriesObj = @()
    for ($i = 0; $i -lt $UserEntries.Count; $i++) {
        $userEntriesObj += [pscustomobject]@{ Scope = 'User'; Index = $i; GlobalOrder = $offset + $i; Original = $UserEntries[$i] }
    }

    foreach ($entry in @($machineEntriesObj + $userEntriesObj)) {
        $classified += Get-PathEntryClassification -Entry $entry
    }

    $duplicates = @(
        $classified |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Canonical) } |
            Group-Object Canonical |
            Where-Object { $_.Count -gt 1 } |
            Sort-Object Count -Descending
    )

    $crossScopeDuplicateGroups = @(
        $duplicates | Where-Object {
            ($_.Group | Select-Object -ExpandProperty Scope -Unique).Count -gt 1
        }
    )

    $missing = @($classified | Where-Object { $_.ExistenceStatus -eq 'Missing' })
    $unknown = @($classified | Where-Object { $_.ExistenceStatus -eq 'Unknown' })
    $stale = @($classified | Where-Object { $_.StaleAccount })
    $empty = @($classified | Where-Object { $_.IsEmpty })

    $collisions = @()
    if ($IncludeCollisions) {
        $collisions = @(Find-CommandCollisions -ClassifiedEntries $classified)
    }

    return [pscustomobject]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        summary = [pscustomobject]@{
            userEntries               = @($UserEntries).Count
            machineEntries            = @($MachineEntries).Count
            totalEntries              = @($classified).Count
            distinctNormalizedEntries = @($classified | Where-Object { $_.Canonical } | Select-Object -ExpandProperty Canonical -Unique).Count
            duplicateGroups           = @($duplicates).Count
            crossScopeDuplicateGroups = @($crossScopeDuplicateGroups).Count
            missingEntries            = @($missing).Count
            unknownEntries            = @($unknown).Count
            staleAccountEntries       = @($stale).Count
            emptyEntries              = @($empty).Count
            collisionCommands         = @($collisions).Count
        }
        entries    = $classified
        duplicates = $duplicates
        missing    = $missing
        unknown    = $unknown
        stale      = $stale
        collisions = $collisions
    }
}

Export-ModuleMember -Function Get-PathEntryClassification, Get-PathDiagnostics, Find-CommandCollisions, Test-StaleAccountPath, Get-PathExistence
