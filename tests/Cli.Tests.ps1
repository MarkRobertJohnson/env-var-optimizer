. (Join-Path $PSScriptRoot '../src/Cli.ps1')

Describe 'Cli Help' {
    It 'shows root help when no args are provided' {
        $helpText = (Invoke-PathOptCli -CliArgs @() | Out-String)

        $helpText.Contains('PATH Optimizer (Windows PowerShell)') | Should Be $true
        $helpText.Contains('Help:') | Should Be $true
    }

    It 'shows command help for analyze --help' {
        $helpText = (Invoke-PathOptCli -CliArgs @('analyze', '--help') | Out-String)

        $helpText.Contains('Command: analyze') | Should Be $true
        $helpText.Contains('./pathopt.ps1 analyze [--json] [--out <file>]') | Should Be $true
    }

    It 'shows command help when help token appears after options' {
        $helpText = (Invoke-PathOptCli -CliArgs @('plan', '--scope', 'both', '--help') | Out-String)

        $helpText.Contains('Command: plan') | Should Be $true
        $helpText.Contains('--scope <value>') | Should Be $true
    }

    It 'routes help command for top-level topics' {
        $helpText = (Invoke-PathOptCli -CliArgs @('help', 'apply') | Out-String)

        $helpText.Contains('Command: apply') | Should Be $true
        $helpText.Contains('--plan <file>') | Should Be $true
    }

    It 'shows shim help for shim --help' {
        $helpText = (Invoke-PathOptCli -CliArgs @('shim', '--help') | Out-String)

        $helpText.Contains('Command: shim') | Should Be $true
        $helpText.Contains('Subcommands:') | Should Be $true
    }

    It 'shows shim sync help when requesting subcommand help' {
        $helpText = (Invoke-PathOptCli -CliArgs @('shim', 'sync', '--help') | Out-String)

        $helpText.Contains('Command: shim sync') | Should Be $true
        $helpText.Contains('--manifest <file>') | Should Be $true
        $helpText.Contains('Manifest JSON example:') | Should Be $true
        $helpText.Contains('"shims": [') | Should Be $true
    }

    It 'routes help shim install through help command' {
        $helpText = (Invoke-PathOptCli -CliArgs @('help', 'shim', 'install') | Out-String)

        $helpText.Contains('Command: shim install') | Should Be $true
        $helpText.Contains('--state <file>') | Should Be $true
    }

    It 'preserves unknown option errors for non-help command invocations' {
        $didThrow = $false
        try {
            Invoke-PathOptCli -CliArgs @('analyze', '--bogus') | Out-Null
        }
        catch {
            $didThrow = $true
            $_.Exception.Message.Contains('Unknown analyze option: --bogus') | Should Be $true
        }

        $didThrow | Should Be $true
    }
}

Describe 'Installer Manifest Defaults' {
    It 'allows positional tail arguments for shimgen in the default command manifest' {
        $manifestPath = Join-Path $PSScriptRoot '../examples/pathopt-commands.manifest.json'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $shimgen = @($manifest.shims | Where-Object { $_.name -eq 'shimgen' } | Select-Object -First 1)
        $shimgen.Count | Should Be 1

        [bool]$shimgen[0].args.allowPositionalTail | Should Be $true
    }
}

Describe 'Shim Sync Positional Target' {
    It 'supports positional target glob shorthand with auto-generated shim names' {
        $root = Join-Path $env:TEMP ('pathopt-cli-shim-shortcut-' + [guid]::NewGuid().ToString('N'))
        $toolDir = Join-Path $root 'tools'
        $binDir = Join-Path $root 'bin'

        New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
        '@echo off' | Set-Content -Path (Join-Path $toolDir 'foo.bat') -Encoding ASCII
        '@echo off' | Set-Content -Path (Join-Path $toolDir 'bar.bat') -Encoding ASCII

        $targetPattern = Join-Path $toolDir '*.bat'
        $result = Invoke-PathOptCli -CliArgs @('shim', 'sync', $targetPattern, '--bin-dir', $binDir, '--whatif')

        $result.shimCount | Should Be 2
        @($result.launchers | Where-Object { $_.name -eq 'foo' -or $_.name -eq 'bar' }).Count | Should Be 4
        [System.IO.Path]::GetFileName([string]$result.manifestPath) | Should Be 'shim-auto-positional.json'

        Remove-Item -Recurse -Force -Path $root
    }

    It 'rejects mixing positional target shorthand with explicit target options' {
        $didThrow = $false
        try {
            Invoke-PathOptCli -CliArgs @('shim', 'sync', 'C:\\tools\\*.bat', '--target', 'C:\\tools\\foo.bat') | Out-Null
        }
        catch {
            $didThrow = $true
            $_.Exception.Message.Contains('Use either positional <target> shorthand or --name/--target options, not both.') | Should Be $true
        }

        $didThrow | Should Be $true
    }
}
