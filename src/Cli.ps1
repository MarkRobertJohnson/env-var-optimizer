Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathNormalize.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathSource.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathClassify.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathPlan.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathApply.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PathRefresh.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ShimBuilder.psm1') -Force -DisableNameChecking

function Show-PathOptHelp {
    [CmdletBinding()]
    param()

    Show-PathOptTopicHelp -Topics @()
}

function Write-PathOptHelpLines {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $Lines -join [Environment]::NewLine | Write-Output
}

function Test-IsHelpToken {
    [CmdletBinding()]
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $false
    }

    $normalized = $Token.ToLowerInvariant()
    return $normalized -in @('--help', '-h', 'help')
}

function Test-ArgsContainHelp {
    [CmdletBinding()]
    param([string[]]$Args)

    foreach ($arg in @($Args)) {
        if (Test-IsHelpToken -Token $arg) {
            return $true
        }
    }

    return $false
}

function Test-PathOptDirectoryWritable {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $probePath = Join-Path $Path ("pathopt-write-test-" + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [System.IO.File]::Open(
            $probePath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $stream.Dispose()
        Remove-Item -LiteralPath $probePath -Force
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $probePath -PathType Leaf) {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        }

        return $false
    }
}

function Get-PathOptDefaultDataRoot {
    [CmdletBinding()]
    param()

    $location = Get-Location
    if ($location.Provider.Name -eq 'FileSystem' -and (Test-PathOptDirectoryWritable -Path $location.ProviderPath)) {
        return Join-Path $location.ProviderPath '.pathopt'
    }

    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }

    if (Test-PathOptDirectoryWritable -Path $localAppData) {
        return Join-Path $localAppData 'pathopt'
    }

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    }

    if (Test-PathOptDirectoryWritable -Path $userProfile) {
        return Join-Path $userProfile '.pathopt'
    }

    throw 'Unable to resolve a writable PATH Optimizer data directory.'
}

function Get-PathOptDefaultPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChildPath
    )

    return Join-Path (Get-PathOptDefaultDataRoot) $ChildPath
}

function Show-PathOptTopicHelp {
    [CmdletBinding()]
    param([string[]]$Topics)

    $normalizedTopics = @()
    foreach ($topic in @($Topics)) {
        if (-not [string]::IsNullOrWhiteSpace($topic)) {
            $normalizedTopics += $topic.ToLowerInvariant()
        }
    }

    $topicKey = ($normalizedTopics -join ' ').Trim()

    switch ($topicKey) {
        '' { Show-PathOptRootHelp; return }
        'analyze' { Show-AnalyzeHelp; return }
        'plan' { Show-PlanHelp; return }
        'apply' { Show-ApplyHelp; return }
        'rollback' { Show-RollbackHelp; return }
        'add' { Show-AddHelp; return }
        'refresh' { Show-RefreshHelp; return }
        'shim' { Show-ShimHelp; return }
        'shim sync' { Show-ShimSyncHelp; return }
        'shim install' { Show-ShimInstallHelp; return }
        'doctor' { Show-DoctorHelp; return }
        default { throw "Unknown help topic: $topicKey" }
    }
}

function Show-PathOptRootHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'PATH Optimizer (Windows PowerShell)',
        'Safely inspect, plan, and update PATH across User and Machine scopes.',
        '',
        'Usage:',
        '  ./pathopt.ps1 analyze [--json] [--out <file>]',
        '  ./pathopt.ps1 plan [--json] [--out <file>] [--scope user|machine|both]',
        '  ./pathopt.ps1 apply --plan <file> [--backup-dir <dir>] [--whatif]',
        '  ./pathopt.ps1 rollback --snapshot <file> [--whatif]',
        '  ./pathopt.ps1 add <path> [--scope user|machine] [--position prepend|append] [--force] [--whatif]',
        '  ./pathopt.ps1 refresh [--scope path|all|<name>] [--whatif]',
        '  ./pathopt.ps1 shim sync [--manifest <file> | --name <shim> --target <path> [--launcher-type cmd|ps1|cmd+ps1]] [--bin-dir <dir>] [--whatif]',
        '  ./pathopt.ps1 shim install [--manifest <file>] [--state <file>] [--bin-dir <dir>] [--whatif]',
        '  ./pathopt.ps1 doctor [--json] [--out <file>]',
        '',
        'Help:',
        '  ./pathopt.ps1 <command> --help',
        '  ./pathopt.ps1 help <command>',
        '  ./pathopt.ps1 help shim <sync|install>',
        '',
        'Examples:',
        '  ./pathopt.ps1 analyze --help',
        '  ./pathopt.ps1 help plan',
        '  ./pathopt.ps1 shim sync --help'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-AnalyzeHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: analyze',
        'What it does:',
        '  Captures current PATH state and diagnostics (duplicates, stale entries, collisions).',
        '',
        'Usage:',
        '  ./pathopt.ps1 analyze [--json] [--out <file>]',
        '',
        'Arguments:',
        '  --json        Emit JSON to stdout instead of PowerShell objects.',
        '  --out <file>  Also write JSON payload to a file path.',
        '',
        'Examples:',
        '  ./pathopt.ps1 analyze',
        '  ./pathopt.ps1 analyze --json',
        '  ./pathopt.ps1 analyze --out .pathopt/analyze.json --json'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-PlanHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: plan',
        'What it does:',
        '  Builds an optimization plan and writes the plan JSON to disk.',
        '',
        'Usage:',
        '  ./pathopt.ps1 plan [--json] [--out <file>] [--scope user|machine|both]',
        '',
        'Arguments:',
        '  --json                 Emit plan metadata + plan payload as JSON to stdout.',
        '  --out <file>           Path where plan JSON is written. Defaults to .pathopt/plans/.',
        '  --scope <value>        user, machine, or both (default: both).',
        '',
        'Examples:',
        '  ./pathopt.ps1 plan',
        '  ./pathopt.ps1 plan --scope both --json',
        '  ./pathopt.ps1 plan --scope user --out .pathopt/plans/user-plan.json'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-ApplyHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: apply',
        'What it does:',
        '  Applies a previously generated plan and writes a rollback snapshot first.',
        '',
        'Usage:',
        '  ./pathopt.ps1 apply --plan <file> [--backup-dir <dir>] [--whatif]',
        '',
        'Arguments:',
        '  --plan <file>          Required. Path to a plan JSON file from plan command.',
        '  --backup-dir <dir>     Snapshot output directory (default: .pathopt/backups).',
        '  --whatif               Preview actions without changing environment values.',
        '',
        'Examples:',
        '  ./pathopt.ps1 apply --plan .pathopt/plans/plan.json --whatif',
        '  ./pathopt.ps1 apply --plan .pathopt/plans/plan.json',
        '  ./pathopt.ps1 apply --plan .pathopt/plans/plan.json --backup-dir backup'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-RollbackHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: rollback',
        'What it does:',
        '  Restores PATH values from a snapshot captured during apply.',
        '',
        'Usage:',
        '  ./pathopt.ps1 rollback --snapshot <file> [--whatif]',
        '',
        'Arguments:',
        '  --snapshot <file>      Required. Snapshot JSON file path.',
        '  --whatif               Preview rollback changes without applying.',
        '',
        'Examples:',
        '  ./pathopt.ps1 rollback --snapshot .pathopt/backups/path-snapshot-20260207-192743.json --whatif',
        '  ./pathopt.ps1 rollback --snapshot .pathopt/backups/path-snapshot-20260207-192743.json'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-AddHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: add',
        'What it does:',
        '  Adds one path entry to User or Machine PATH with validation and warnings.',
        '',
        'Usage:',
        '  ./pathopt.ps1 add <path> [--scope user|machine] [--position prepend|append] [--force] [--whatif]',
        '',
        'Arguments:',
        '  <path>                 Required. Single directory path to add (quote if it has spaces).',
        '  --scope <value>        user or machine (default: user).',
        '  --position <value>     prepend or append (default: append).',
        '  --force                Overrides critical length warnings.',
        '  --whatif               Preview changes without writing environment values.',
        '',
        'Examples:',
        '  ./pathopt.ps1 add "C:\Tools\bin"',
        '  ./pathopt.ps1 add "C:\MyApp\bin" --position prepend',
        '  ./pathopt.ps1 add "C:\Tools\bin" --scope machine --whatif'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-RefreshHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: refresh',
        'What it does:',
        '  Refreshes the current process environment from User and Machine values.',
        '',
        'Usage:',
        '  ./pathopt.ps1 refresh [--scope path|all|<name>] [--whatif]',
        '',
        'Arguments:',
        '  --scope <value>        path (default), all, or a specific variable name.',
        '  --whatif               Preview refresh operations only.',
        '',
        'Examples:',
        '  ./pathopt.ps1 refresh',
        '  ./pathopt.ps1 refresh --scope all',
        '  ./pathopt.ps1 refresh --scope JAVA_HOME --whatif'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-ShimHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: shim',
        'What it does:',
        '  Creates or reconciles shim launcher files in your bin directory.',
        '',
        'Usage:',
        '  ./pathopt.ps1 shim sync [options]',
        '  ./pathopt.ps1 shim install [options]',
        '',
        'Subcommands:',
        '  sync                   Build/update shims from a manifest or single name+target pair.',
        '  install                Idempotent install using a full command manifest and state file.',
        '',
        'Help:',
        '  ./pathopt.ps1 shim sync --help',
        '  ./pathopt.ps1 shim install --help'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-ShimSyncHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: shim sync',
        'What it does:',
        '  Generates launcher shims directly from a manifest, --name/--target input, or a positional target/glob.',
        '',
        'Usage:',
        '  ./pathopt.ps1 shim sync [--manifest <file> | --name <shim> --target <path> [--launcher-type cmd|ps1|cmd+ps1] | <target>] [--bin-dir <dir>] [--whatif]',
        '',
        'Arguments:',
        '  --manifest <file>      Manifest path containing one or more shim definitions.',
        '  --name <shim>          Shim name for single-shim mode.',
        '  --target <path>        Target executable/script for single-shim mode.',
        '  --launcher-type <v>    cmd, ps1, or cmd+ps1 (default: cmd+ps1 in single-shim mode).',
        '  --bin-dir <dir>        Launcher output directory (default: C:\\Tools\\bin).',
        '  --whatif               Preview generated/updated launchers.',
        '  <target>               Positional shorthand target path or wildcard glob (for example: tools\\*.bat).',
        '',
        'Notes:',
        '  Use either --manifest OR (--name + --target) OR positional <target>.',
        '  In manifest mode, target supports wildcards (for example: tools\\*.bat).',
        '  If wildcard target matches multiple files, omit name to auto-generate shim names from file names.',
        '',
        'Manifest JSON example:',
        '  {',
        '    "version": 1,',
        '    "shims": [',
        '      {',
        '        "name": "envrefresh",',
        '        "target": "D:\\dev\\env-var-optimizer\\pathopt.ps1",',
        '        "launcherType": "ps1"',
        '      }',
        '    ]',
        '  }',
        '',
        'Examples:',
        '  ./pathopt.ps1 shim sync --manifest examples/shim-manifest.sample.json',
        '  ./pathopt.ps1 shim sync --name envrefresh --target D:\\dev\\env-var-optimizer\\pathopt.ps1 --launcher-type ps1',
        '  ./pathopt.ps1 shim sync --name pathdoctor --target D:\\dev\\env-var-optimizer\\pathopt.ps1 --whatif',
        '  ./pathopt.ps1 shim sync C:\\Users\\you\\AppData\\Local\\miniconda3\\condabin\\*.bat'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-ShimInstallHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: shim install',
        'What it does:',
        '  Reconciles the project command manifest with the bin directory and tracked state.',
        '',
        'Usage:',
        '  ./pathopt.ps1 shim install [--manifest <file>] [--state <file>] [--bin-dir <dir>] [--whatif]',
        '',
        'Arguments:',
        '  --manifest <file>      Full installer manifest (default: examples/pathopt-commands.manifest.json).',
        '  --state <file>         Installer state file path (default: .pathopt/state/shim-install-state.json).',
        '  --bin-dir <dir>        Launcher output directory (default: C:\\Tools\\bin).',
        '  --whatif               Preview create/update/remove operations.',
        '',
        'Examples:',
        '  ./pathopt.ps1 shim install',
        '  ./pathopt.ps1 shim install --manifest examples/pathopt-commands.manifest.json --state .pathopt/state/shim-install-state.json',
        '  ./pathopt.ps1 shim install --bin-dir C:\\Tools\\bin --whatif'
    )

    Write-PathOptHelpLines -Lines $lines
}

function Show-DoctorHelp {
    [CmdletBinding()]
    param()

    $lines = @(
        'Command: doctor',
        'What it does:',
        '  Runs quick health checks for PATH diagnostics and common command availability.',
        '',
        'Usage:',
        '  ./pathopt.ps1 doctor [--json] [--out <file>]',
        '',
        'Arguments:',
        '  --json        Emit JSON to stdout.',
        '  --out <file>  Also write JSON payload to a file path.',
        '',
        'Examples:',
        '  ./pathopt.ps1 doctor',
        '  ./pathopt.ps1 doctor --json',
        '  ./pathopt.ps1 doctor --json --out .pathopt/doctor.json'
    )

    Write-PathOptHelpLines -Lines $lines
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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-AnalyzeHelp
        return
    }

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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-PlanHelp
        return
    }

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
        $planDir = Get-PathOptDefaultPath -ChildPath 'plans'
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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-ApplyHelp
        return
    }

    $planPath = $null
    $backupDir = Get-PathOptDefaultPath -ChildPath 'backups'
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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-RollbackHelp
        return
    }

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

    if (Test-ArgsContainHelp -Args $Args) {
        $shimTopic = 'shim'
        foreach ($arg in @($Args)) {
            $normalizedArg = $arg.ToLowerInvariant()
            if ($normalizedArg -in @('sync', 'install')) {
                $shimTopic = "shim $normalizedArg"
                break
            }
        }

        Show-PathOptTopicHelp -Topics @($shimTopic)
        return
    }

    if ($Args.Count -eq 0) {
        throw 'shim requires a subcommand (sync|install).'
    }

    $subCommand = $Args[0].ToLowerInvariant()
    if ($subCommand -notin @('sync', 'install')) {
        throw "Unsupported shim subcommand: $subCommand"
    }

    if ($subCommand -eq 'install') {
        $manifestPath = $null
        $statePath = $null
        $binDir = 'C:\\Tools\\bin'
        $whatIf = $false

        for ($i = 1; $i -lt $Args.Count; $i++) {
            switch ($Args[$i]) {
                '--manifest' { $manifestPath = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--manifest' }
                '--state' { $statePath = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--state' }
                '--bin-dir' { $binDir = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--bin-dir' }
                '--whatif' { $whatIf = $true }
                default { throw "Unknown shim install option: $($Args[$i])" }
            }
        }

        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            $manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'examples\pathopt-commands.manifest.json'
        }

        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Installer manifest not found: $manifestPath"
        }

        if ([string]::IsNullOrWhiteSpace($statePath)) {
            $statePath = Get-PathOptDefaultPath -ChildPath 'state\shim-install-state.json'
        }

        return Install-PathShims -ManifestPath $manifestPath -StatePath $statePath -BinDir $binDir -WhatIf:$whatIf
    }

    $manifestPath = $null
    $shimName = $null
    $shimTarget = $null
    $positionalTarget = $null
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
                if ($launcherType -notin @('cmd', 'ps1', 'cmd+ps1')) {
                    throw "Invalid --launcher-type value: $launcherType. Use 'cmd', 'ps1', or 'cmd+ps1'."
                }
            }
            '--bin-dir' { $binDir = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--bin-dir' }
            '--whatif' { $whatIf = $true }
            default {
                if ($Args[$i].StartsWith('-')) {
                    throw "Unknown shim sync option: $($Args[$i])"
                }

                if (-not [string]::IsNullOrWhiteSpace($positionalTarget)) {
                    throw 'shim sync accepts at most one positional target/glob argument.'
                }

                $positionalTarget = $Args[$i]
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($manifestPath) -and (-not [string]::IsNullOrWhiteSpace($shimName) -or -not [string]::IsNullOrWhiteSpace($shimTarget) -or -not [string]::IsNullOrWhiteSpace($positionalTarget))) {
        throw 'Specify either --manifest or (--name and --target) or a positional <target>, not both.'
    }

    if (-not [string]::IsNullOrWhiteSpace($positionalTarget) -and (-not [string]::IsNullOrWhiteSpace($shimName) -or -not [string]::IsNullOrWhiteSpace($shimTarget))) {
        throw 'Use either positional <target> shorthand or --name/--target options, not both.'
    }

    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        if (-not [string]::IsNullOrWhiteSpace($positionalTarget)) {
            $shimTarget = $positionalTarget
        }

        $isNamedSingleShim = (-not [string]::IsNullOrWhiteSpace($shimName) -and -not [string]::IsNullOrWhiteSpace($shimTarget))
        $isPositionalShortcut = (-not [string]::IsNullOrWhiteSpace($shimTarget) -and [string]::IsNullOrWhiteSpace($shimName))

        if (-not $isNamedSingleShim -and -not $isPositionalShortcut) {
            throw 'shim sync requires either --manifest <file>, --name <shim> --target <path>, or positional <target>. '
        }

        $generatedManifestDir = Get-PathOptDefaultPath -ChildPath 'manifests'
        New-Item -ItemType Directory -Force -Path $generatedManifestDir | Out-Null

        $safeNameSource = if ([string]::IsNullOrWhiteSpace($shimName)) { 'positional' } else { $shimName }
        $safeName = ($safeNameSource -replace '[^A-Za-z0-9_.-]', '_')
        $generatedManifestPath = Join-Path $generatedManifestDir ("shim-auto-$safeName.json")

        $manifestObject = [pscustomobject]@{
            version = 1
            shims   = @(
                if ($isPositionalShortcut) {
                    [pscustomobject]@{
                        target       = $shimTarget
                        launcherType = $launcherType
                    }
                }
                else {
                    [pscustomobject]@{
                        name         = $shimName
                        target       = $shimTarget
                        launcherType = $launcherType
                    }
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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-DoctorHelp
        return
    }

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

    if (Test-ArgsContainHelp -Args $Args) {
        Show-AddHelp
        return
    }

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

function Invoke-RefreshCommand {
    [CmdletBinding()]
    param([string[]]$Args)

    if (Test-ArgsContainHelp -Args $Args) {
        Show-RefreshHelp
        return
    }

    $scope = 'path'
    $whatIf = $false

    for ($i = 0; $i -lt $Args.Count; $i++) {
        switch ($Args[$i]) {
            '--scope' { $scope = Get-RequiredOptionValue -Args $Args -Index ([ref]$i) -OptionName '--scope' }
            '--whatif' { $whatIf = $true }
            default { throw "Unknown refresh option: $($Args[$i])" }
        }
    }

    return Invoke-EnvironmentRefresh -Scope $scope -WhatIf:$whatIf
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
        'refresh' { Invoke-RefreshCommand -Args $rest; break }
        'shim' { Invoke-ShimCommand -Args $rest; break }
        'doctor' { Invoke-DoctorCommand -Args $rest; break }
        'help' { Show-PathOptTopicHelp -Topics $rest; break }
        '--help' { Show-PathOptHelp; break }
        '-h' { Show-PathOptHelp; break }
        default { throw "Unknown command: $command" }
    }
}
