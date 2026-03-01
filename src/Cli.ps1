Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathSource.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathClassify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathPlan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathApply.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ShimBuilder.psm1') -Force -DisableNameChecking

function Show-PathOptHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'PATH Optimizer (Windows PowerShell)',
        '',
        'Usage:',
        '  ./pathopt.ps1 analyze [--json] [--out <file>]',
        '  ./pathopt.ps1 plan [--json] [--out <file>] [--scope user|machine|both]',
        '  ./pathopt.ps1 apply --plan <file> [--backup-dir <dir>] [--whatif]',
        '  ./pathopt.ps1 rollback --snapshot <file> [--whatif]',
        '  ./pathopt.ps1 add <path> [--scope user|machine] [--position prepend|append] [--force] [--whatif]',
        '  ./pathopt.ps1 shim sync [--manifest <file> | --name <shim> --target <path> [--launcher-type cmd|cmd+ps1]] [--bin-dir <dir>] [--whatif]',
        '  ./pathopt.ps1 doctor [--json] [--out <file>]'
    )

    $lines -join [Environment]::NewLine | Write-Output
}

function Get-RequiredOptionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Args,
        [Parameter(Mandatory)]
        [ref]$Index,
        [Parameter(Mandatory)]
        [string]$OptionName
    )

    if ($Index.Value + 1 -ge $Args.Count) {
        throw "Missing value for option $OptionName"
    }

    $Index.Value++
    return $Args[$Index.Value]
}

function Write-CommandOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Payload,
        [switch]$AsJson,
        [string]$OutFile
    )

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $dir = Split-Path -Parent $OutFile
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        $Payload | ConvertTo-Json -Depth 32 | Set-Content -Path $OutFile -Encoding UTF8
    }

    if ($AsJson) {
        $Payload | ConvertTo-Json -Depth 32
        return
    }

    $Payload
}

function Get-CurrentPathEntries {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        userEntries    = @((Get-PathEntries -Scope User | Select-Object -ExpandProperty Original))
        machineEntries = @((Get-PathEntries -Scope Machine | Select-Object -ExpandProperty Original))
    }
}

function Invoke-AnalyzeCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    $asJson = $false
    $outFile = $null

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--json' { $asJson = $true }
            '--out' { $outFile = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--out' }
            default { throw "Unknown analyze option: $($Args[$i])" }
        }
    }

    $pathState = Get-EnvironmentPathState
    $current = Get-CurrentPathEntries
    $diagnostics = Get-PathDiagnostics -UserEntries $current.userEntries -MachineEntries $current.machineEntries -IncludeCollisions

    $payload = [pscustomobject]@{
        version     = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        source      = $pathState
        diagnostics = $diagnostics
    }

    Write-CommandOutput -Payload $payload -AsJson:$asJson -OutFile $outFile
}

function Invoke-PlanCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    $asJson = $false
    $outFile = $null
    $scope = 'both'

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--json' { $asJson = $true }
            '--out' { $outFile = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--out' }
            '--scope' {
                $scope = (Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--scope').ToLowerInvariant()
                if ($scope -notin @('user', 'machine', 'both')) {
                    throw "Invalid --scope value: $scope"
                }
            }
            default { throw "Unknown plan option: $($Args[$i])" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($outFile)) {
        $planDir = Join-Path (Get-Location) '.pathopt\\plans'
        New-Item -ItemType Directory -Force -Path $planDir | Out-Null
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outFile = Join-Path $planDir ("path-plan-$timestamp.json")
    }

    $current = Get-CurrentPathEntries
    $plan = New-PathOptimizationPlan -UserEntries $current.userEntries -MachineEntries $current.machineEntries -Scope $scope -ScopePolicy SharedToMachine

    $plan | ConvertTo-Json -Depth 32 | Set-Content -Path $outFile -Encoding UTF8

    $payload = [pscustomobject]@{
        planPath = (Resolve-Path -LiteralPath $outFile).Path
        plan     = $plan
    }

    Write-CommandOutput -Payload $payload -AsJson:$asJson -OutFile $null
}

function Invoke-ApplyCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    $planPath = $null
    $backupDir = Join-Path (Get-Location) '.pathopt\\backups'
    $whatIf = $false

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--plan' { $planPath = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--plan' }
            '--backup-dir' { $backupDir = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--backup-dir' }
            '--whatif' { $whatIf = $true }
            default { throw "Unknown apply option: $($Args[$i])" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($planPath)) {
        throw '--plan is required for apply'
    }

    Invoke-PathPlanApply -PlanPath $planPath -BackupDir $backupDir -WhatIf:$whatIf
}

function Invoke-RollbackCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    $snapshotPath = $null
    $whatIf = $false

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--snapshot' { $snapshotPath = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--snapshot' }
            '--whatif' { $whatIf = $true }
            default { throw "Unknown rollback option: $($Args[$i])" }
        }
    }

    if ([string]::IsNullOrWhiteSpace($snapshotPath)) {
        throw '--snapshot is required for rollback'
    }

    Invoke-PathRollback -SnapshotPath $snapshotPath -WhatIf:$whatIf
}

function Invoke-ShimCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    if ($Args.Count -eq 0) {
        throw 'shim requires a subcommand (sync).'
    }

    $subCommand = $Args[0].ToLowerInvariant()
    if ($subCommand -ne 'sync') {
        throw "Unsupported shim subcommand: $subCommand"
    }

    $manifestPath = $null
    $shimName = $null
    $shimTarget = $null
    $launcherType = 'cmd+ps1'
    $binDir = 'C:\\Tools\\bin'
    $whatIf = $false

    for ($i = 1; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--manifest' { $manifestPath = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--manifest' }
            '--name' { $shimName = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--name' }
            '--target' { $shimTarget = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--target' }
            '--launcher-type' {
                $launcherType = (Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--launcher-type').ToLowerInvariant()
                if ($launcherType -notin @('cmd', 'cmd+ps1')) {
                    throw "Invalid --launcher-type value: $launcherType. Use 'cmd' or 'cmd+ps1'."
                }
            }
            '--bin-dir' { $binDir = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--bin-dir' }
            '--whatif' { $whatIf = $true }
            default { throw "Unknown shim sync option: $($Args[$i])" }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (-not [string]::IsNullOrWhiteSpace($shimName) -or -not [string]::IsNullOrWhiteSpace($shimTarget))) {
        throw 'Specify either --manifest or (--name and --target), not both.'
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        if ([string]::IsNullOrWhiteSpace($shimName) -or [string]::IsNullOrWhiteSpace($shimTarget)) {
            throw 'shim sync requires either --manifest <file> or --name <shim> --target <path>.'
        }

        $generatedManifestDir = Join-Path (Get-Location) '.pathopt\\manifests'
        New-Item -ItemType Directory -Force -Path $generatedManifestDir | Out-Null

        $safeName = ($shimName -replace '[^A-Za-z0-9_.-]', '_')
        $generatedManifestPath = Join-Path $generatedManifestDir ("shim-auto-$safeName.json")

        $manifestObject = [pscustomobject]@{
            version = 1
            shims   = @(
                [pscustomobject]@{
                    name         = $shimName
                    target       = $shimTarget
                    launcherType = $launcherType
                }
            )
        }

        $manifestObject | ConvertTo-Json -Depth 16 | Set-Content -Path $generatedManifestPath -Encoding UTF8

        $manifestPath = $generatedManifestPath
    }

    Sync-PathShims -ManifestPath $manifestPath -BinDir $binDir -WhatIf:$whatIf
}

function Invoke-DoctorCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    $asJson = $false
    $outFile = $null

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--json' { $asJson = $true }
            '--out' { $outFile = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--out' }
            default { throw "Unknown doctor option: $($Args[$i])" }
        }
    }

    $current = Get-CurrentPathEntries
    $diagnostics = Get-PathDiagnostics -UserEntries $current.userEntries -MachineEntries $current.machineEntries -IncludeCollisions

    $commands = @('git', 'node', 'python', 'pwsh')
    $commandChecks = @()
    foreach ($name in $commands) {
        $resolved = Get-Command -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        $commandChecks += [pscustomobject]@{
            command = $name
            found   = [bool]($null -ne $resolved)
            source  = if ($null -ne $resolved) { $resolved.Source } else { $null }
        }
    }

    $payload = [pscustomobject]@{
        version     = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        processPath = [pscustomobject]@{
            length     = $env:Path.Length
            entryCount = (Split-PathVariableValue -Value $env:Path).Count
        }
        diagnostics = $diagnostics.summary
        commands    = $commandChecks
    }

    Write-CommandOutput -Payload $payload -AsJson:$asJson -OutFile $outFile
}

function Invoke-AddCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    if ($Args.Count -eq 0) {
        throw 'add requires a path argument. Usage: pathopt.ps1 add <path> [--scope user|machine] [--position prepend|append] [--force] [--whatif]'
    }

    $pathToAdd = $null
    $scope = 'User'
    $position = 'Append'
    $force = $false
    $whatIf = $false

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--scope' {
                $scope = (Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--scope')
                if ($scope -imatch '^user$') { $scope = 'User' }
                elseif ($scope -imatch '^machine$') { $scope = 'Machine' }
                else { throw "Invalid --scope value: $scope. Use 'user' or 'machine'." }
            }
            '--position' {
                $position = (Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--position')
                if ($position -imatch '^prepend$') { $position = 'Prepend' }
                elseif ($position -imatch '^append$') { $position = 'Append' }
                else { throw "Invalid --position value: $position. Use 'prepend' or 'append'." }
            }
            '--force' { $force = $true }
            '--whatif' { $whatIf = $true }
            default {
                if ($Args[$i].StartsWith('-')) {
                    throw "Unknown add option: $($Args[$i])"
                }
                if ($null -ne $pathToAdd) {
                    throw "Multiple paths specified. Only one path can be added at a time."
                }
                $pathToAdd = $Args[$i]
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($pathToAdd)) {
        throw 'add requires a path argument.'
    }

    $result = Add-PathEntry -Path $pathToAdd -Scope $scope -Position $position -Force:$force -WhatIf:$whatIf

    # Display warnings
    foreach ($warning in $result.warnings) {
        $prefix = if ($warning.Level -eq 'Critical') { 'CRITICAL' } else { 'WARNING' }
        Write-Warning "[$prefix] $($warning.Message)"
    }

    # Output result
    Write-Output $result.message

    if ($result.alreadyExists -and -not $result.added) {
        return $result
    }

    if (-not $result.added -and $result.warnings.Count -gt 0) {
        Write-Warning "Use --force to override critical warnings."
    }

    return $result
}

function Invoke-PathOptCli {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$CliArgs
    )

    if ($null -eq $CliArgs -or $CliArgs.Count -eq 0) {
        Show-PathOptHelp
        return
    }

    $command = $CliArgs[0].ToLowerInvariant()
    $rest = @()
    if ($CliArgs.Count -gt 1) {
        $rest = $CliArgs[1..($CliArgs.Count - 1)]
    }

    switch ($command) {
        'analyze' { Invoke-AnalyzeCommand -Args $rest; break }
        'plan' { Invoke-PlanCommand -Args $rest; break }
        'apply' { Invoke-ApplyCommand -Args $rest; break }
        'rollback' { Invoke-RollbackCommand -Args $rest; break }
        'add' { Invoke-AddCommand -Args $rest; break }
        'shim' { Invoke-ShimCommand -Args $rest; break }
        'doctor' { Invoke-DoctorCommand -Args $rest; break }
        'help' { Show-PathOptHelp; break }
        '--help' { Show-PathOptHelp; break }
        '-h' { Show-PathOptHelp; break }
        default { throw "Unknown command: $command" }
    }
}
