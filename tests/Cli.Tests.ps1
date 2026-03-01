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
